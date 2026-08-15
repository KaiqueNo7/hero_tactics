--[[
	MatchManager.lua
	ModuleScript — ServerScriptService/Modules/MatchManager

	Estado autoritativo da partida: draft alternado (1,2,1,2), movimento,
	combate, skills, turnos cronometrados e revanche.

	A partida tem sempre DOIS lados. O lado 2 pode ser um bot (partida solo)
	ou outro jogador (PvP) — o resto do módulo não faz distinção, só olha
	`side.isBot` na hora de decidir quem joga sozinho. Cada jogador recebe seu
	próprio snapshot, com `isMine`/`isMyTurn`/`winner` já do ponto de vista dele.

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
local BOT_ACTION_DELAY = 0.7
local COUNTER_ATTACK_DELAY = 0.4

local BOT_ID = "BOT"

local match = nil
local turnToken = 0
local SkillApi

-- declaradas cedo porque se chamam entre si
local BeginTurn, BotPlayTurn, BotPlaceOne, AdvancePlacement

-- ===================== ZONAS =====================
-- Casas de largada fixas, uma por coluna, na primeira fileira de cada lado.
local DEPLOY_ZONES = {
	{ "A6", "B7", "C6", "D7", "E6" },
	{ "A1", "B1", "C1", "D1", "E1" },
}

local function BuildDeployZone(hexIds)
	local zone = {}
	for _, hexId in ipairs(hexIds) do
		if HexGrid.GetHex(hexId) then
			table.insert(zone, hexId)
		else
			warn("MatchManager: hex de largada inexistente: " .. hexId)
		end
	end
	return zone
end

-- ===================== LADOS =====================
local function SideOf(ownerId)
	local index = match.sideIndexById[ownerId]
	return index and match.sides[index] or nil
end

local function OpponentSide(ownerId)
	local index = match.sideIndexById[ownerId]
	return match.sides[index == 1 and 2 or 1]
end

local function SideOfPlayer(player)
	for _, side in ipairs(match.sides) do
		if side.player == player then return side end
	end
	return nil
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
	PlaySkillSound = HeroView.PlaySkillSound,
	Say = Say,
}

-- ===================== SNAPSHOT =====================
local function TurnSecondsLeft()
	if not match.turn or GameConfig.TURN_TIME_LIMIT <= 0 then return nil end
	local elapsed = os.clock() - match.turn.startedAt
	return math.max(0, math.floor(GameConfig.TURN_TIME_LIMIT - elapsed))
end

-- O estado é montado por espectador: quem olha precisa saber o que é dele,
-- não quem é "o player" e quem é "o bot".
local function Snapshot(viewerId)
	local viewerSide = SideOf(viewerId)
	local opponent = OpponentSide(viewerId)

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
			isMine = hero.ownerId == viewerId,
			hasMoved = match.turn and match.turn.moved[hero.uid] or false,
			hasAttacked = match.turn and match.turn.attacked[hero.uid] or false,
		})
	end

	local winner = nil
	if match.winner == "draw" then
		winner = "draw"
	elseif match.winner then
		winner = (match.winner == viewerId) and "win" or "loss"
	end

	return {
		phase = match.phase,
		deployZone = viewerSide.zone,
		placedCount = viewerSide.placedCount,
		opponentPlacedCount = opponent.placedCount,
		isMyPlacement = match.sides[match.placementSide].id == viewerId,
		heroesPerPlayer = GameConfig.HEROES_PER_PLAYER,
		usedHeroIds = match.usedHeroIds,
		heroes = heroes,
		turnNumber = match.turn and match.turn.number or 0,
		isMyTurn = match.turn and match.turn.ownerId == viewerId or false,
		turnSecondsLeft = TurnSecondsLeft(),
		turnTimeLimit = GameConfig.TURN_TIME_LIMIT,
		suddenDeath = match.turn and match.turn.number >= GameConfig.SUDDEN_DEATH_START_TURN or false,
		winner = winner,
		message = match.message,
		vsBot = match.vsBot,
		opponentName = opponent.player and opponent.player.DisplayName or "Bot",
	}
end

local function Broadcast(message)
	match.message = message
	for _, side in ipairs(match.sides) do
		if side.player then
			MatchUpdate:FireClient(side.player, Snapshot(side.id))
		end
	end
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
		sideIndex = SideOf(ownerId).index, -- 1 = azul, 2 = vermelho (o HeroView pinta)
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
	HeroView.PlayPlaceSound()
	return hero
end

-- ===================== FIM DE JOGO =====================
local function CheckGameOver()
	local aliveOne = #LivingHeroesOf(match.sides[1].id)
	local aliveTwo = #LivingHeroesOf(match.sides[2].id)

	if aliveOne > 0 and aliveTwo > 0 then return false end

	match.phase = "finished"
	if aliveOne == 0 and aliveTwo == 0 then
		match.winner = "draw"
	else
		match.winner = (aliveTwo == 0) and match.sides[1].id or match.sides[2].id
	end
	return true
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

-- ===================== IA DO BOT =====================
-- Pontua cada combinação (herói, casa de destino, alvo) e executa a melhor,
-- recalculando após cada ação. As habilidades entram na conta: Noctin caça
-- alvo isolado, Blade busca alinhamento, Elaria cola em aliado ferido, os
-- ranged mantêm distância pra não levar contra-ataque, e ninguém tenta bater
-- através de um Taunt.

local TAUNT = GameConfig.ABILITIES.TAUNT
local RANGED = GameConfig.ABILITIES.RANGED

local function HasSkill(hero, key)
	return table.find(hero.abilities, key) ~= nil
end

local function AlliesAdjacentTo(hero, position)
	local list = {}
	for _, neighbor in ipairs(HexGrid.GetNeighbors(position)) do
		local occupant = neighbor.occupiedBy
		if occupant and occupant ~= hero and occupant.isAlive
			and occupant.ownerId == hero.ownerId then
			table.insert(list, occupant)
		end
	end
	return list
end

-- O quanto vale a pena derrubar este inimigo
local function ThreatScore(hero)
	local threat = hero.attack * 3
	if hero.attackRange >= 2 then threat += 2 end
	if HasSkill(hero, "health") then threat += 8 end -- curandeira morre primeiro
	if HasSkill(hero, "clean") then threat += 3 end
	if HasSkill(hero, "poisonAttack") then threat += 4 end
	if HasSkill(hero, "beyondFront") then threat += 3 end
	if HasSkill(hero, "aloneIsBetter") then threat += 3 end
	return threat
end

-- Alcance a partir de uma casa hipotética, já contando que o herói saiu da atual
local function ReachFrom(hero, fromPos, range)
	local isFree = function(hexId)
		if hexId == hero.position or hexId == fromPos then return true end
		return HexGrid.IsFree(hexId)
	end
	return HexGrid.ComputeReach(fromPos, range, isFree)
end

-- Um Taunt inimigo adjacente trava o ataque em qualquer outro alvo
local function TauntBlocks(attacker, target, fromPos)
	if target.ability == TAUNT then return false end

	for _, neighbor in ipairs(HexGrid.GetNeighbors(fromPos)) do
		local occupant = neighbor.occupiedBy
		if occupant and occupant.isAlive
			and occupant.ownerId ~= attacker.ownerId
			and occupant.ability == TAUNT then
			return true
		end
	end
	return false
end

local function EstimateDamage(attacker, target, fromPos)
	local damage = attacker.attack

	-- trustInTeam recalcula no onMove: prevê o ataque já pós-movimento
	if HasSkill(attacker, "trustInTeam") then
		local buffed = attacker.attack > attacker.baseAttack
		local willHaveAlly = #AlliesAdjacentTo(attacker, fromPos) > 0
		if willHaveAlly and not buffed then
			damage += 1
		elseif not willHaveAlly and buffed then
			damage -= 1
		end
	end

	if HasSkill(attacker, "aloneIsBetter") and #AlliesAdjacentTo(target, target.position) == 0 then
		damage *= 2
	end
	if HasSkill(attacker, "brokenDefense") and target.ability == TAUNT then
		damage += 1
	end
	if HasSkill(attacker, "poisonAttack") and FindStatusEffect(target, "poison") then
		damage += 2
	end
	if HasSkill(attacker, "rage") then
		local behind = HexGrid.GetLineBeyond(fromPos, target.position, 1)[1]
		if not (behind and HexGrid.IsFree(behind)) then damage += 1 end
	end

	return damage
end

-- Inimigos extras que o Blade acerta na mesma linha
local function LineHits(attacker, target, fromPos)
	if not HasSkill(attacker, "beyondFront") then return 0 end

	local hits = 0
	for _, hexId in ipairs(HexGrid.GetLineBeyond(fromPos, target.position, 2)) do
		local other = GetHeroAt(hexId)
		if other and other.isAlive and other.ownerId ~= attacker.ownerId then
			hits += 1
		else
			break
		end
	end
	return hits
end

-- Dano que voltaria em contra-ataque (0 se o alvo morre ou não alcança)
local function CounterDamage(attacker, target, fromPos, damage)
	if damage >= target.currentHp then return 0 end
	if HexGrid.Distance(target.position, fromPos) > target.attackRange then return 0 end

	local incoming = target.attack
	if HasSkill(attacker, "autoDefense") then incoming = math.max(0, incoming - 1) end
	return incoming
end

local function ScoreAttack(attacker, target, fromPos)
	if TauntBlocks(attacker, target, fromPos) then return nil end

	local damage = EstimateDamage(attacker, target, fromPos)
	local score = damage * 10

	if damage >= target.currentHp then
		score += 120 + ThreatScore(target) * 4 -- abater é sempre a prioridade
	else
		score += (target.maxHp - target.currentHp) * 2 -- concentra fogo no ferido
		score += ThreatScore(target) * 2
	end

	score += LineHits(attacker, target, fromPos) * 30

	-- veneno novo rende dano ao longo dos turnos seguintes
	if HasSkill(attacker, "poisonAttack") and not FindStatusEffect(target, "poison") then
		score += 15
	end

	-- Ceos se cura batendo
	if HasSkill(attacker, "absorbRoots") and attacker.currentHp < attacker.maxHp then
		score += math.min(attacker.attack, attacker.maxHp - attacker.currentHp) * 5
	end

	-- Elaria limpa veneno dos vizinhos ao atacar
	if HasSkill(attacker, "clean") then
		for _, ally in ipairs(AlliesAdjacentTo(attacker, fromPos)) do
			if #ally.statusEffects > 0 then score += 25 end
		end
	end

	score -= CounterDamage(attacker, target, fromPos, damage) * 7

	return score
end

-- Valor de ocupar uma casa, mesmo sem atacar neste turno
local function ScorePosition(hero, fromPos, enemies)
	local score = 0
	local isTank = hero.ability == TAUNT
	local isRanged = hero.attackRange >= 2

	local nearest = math.huge
	for _, enemy in ipairs(enemies) do
		nearest = math.min(nearest, HexGrid.Distance(fromPos, enemy.position))
	end

	if nearest < math.huge then
		if isRanged then
			-- fica exatamente no alcance: bate sem ser contra-atacado
			score -= math.abs(nearest - hero.attackRange) * 8
		else
			score -= nearest * 5
		end

		if isTank then
			score -= math.abs(nearest - 1) * 8 -- tanque segura a linha de frente
		end
	end

	if HasSkill(hero, "trustInTeam") then
		score += #AlliesAdjacentTo(hero, fromPos) * 10
	end

	-- Elaria cura e limpa vizinhos: cola em quem precisa
	if HasSkill(hero, "health") or HasSkill(hero, "clean") then
		for _, ally in ipairs(AlliesAdjacentTo(hero, fromPos)) do
			if ally.currentHp < ally.maxHp then score += 18 end
			if FindStatusEffect(ally, "poison") then score += 14 end
		end
	end

	if isRanged then
		for _, enemy in ipairs(enemies) do
			if HexGrid.Distance(fromPos, enemy.position) <= 1 then score -= 22 end
		end
	end

	-- Noctin caça quem está sozinho (dano dobrado)
	if HasSkill(hero, "aloneIsBetter") then
		for _, enemy in ipairs(enemies) do
			if #AlliesAdjacentTo(enemy, enemy.position) == 0
				and HexGrid.Distance(fromPos, enemy.position) <= hero.attackRange then
				score += 20
			end
		end
	end

	return score
end

-- Melhor jogada de um herói: para onde ir e quem bater
local function PlanFor(hero, enemies)
	local canMove = not match.turn.moved[hero.uid] and not match.turn.attacked[hero.uid]
	local canAttack = not match.turn.attacked[hero.uid]
	if not canMove and not canAttack then return nil end

	local positions = { [hero.position] = true }
	if canMove then
		for hexId in pairs(HexGrid.ComputeReach(hero.position, hero.moveRange)) do
			if HexGrid.IsFree(hexId) then positions[hexId] = true end
		end
	end

	local best = nil
	for fromPos in pairs(positions) do
		local stayBonus = (fromPos == hero.position) and 2 or 0 -- desempata a favor de ficar
		local positional = ScorePosition(hero, fromPos, enemies) + stayBonus

		local bestTarget, bestAttackScore = nil, nil
		if canAttack then
			local reach = ReachFrom(hero, fromPos, hero.attackRange)
			for _, enemy in ipairs(enemies) do
				if reach[enemy.position] then
					local attackScore = ScoreAttack(hero, enemy, fromPos)
					if attackScore and (not bestAttackScore or attackScore > bestAttackScore) then
						bestTarget, bestAttackScore = enemy, attackScore
					end
				end
			end
		end

		local total = positional + (bestAttackScore or 0)
		if not best or total > best.score then
			best = {
				hero = hero,
				position = fromPos,
				target = bestTarget,
				score = total,
			}
		end
	end

	return best
end

-- ===================== TURNOS =====================
function BotPlayTurn(botId)
	task.spawn(function()
		task.wait(BOT_ACTION_DELAY)

		-- age sempre com quem tem a melhor jogada disponível; o tabuleiro muda
		-- a cada movimento/abate, então o plano é refeito a cada iteração
		local resolved = {}

		for _ = 1, GameConfig.HEROES_PER_PLAYER * 2 do
			if not match or match.phase ~= "battle" or match.turn.ownerId ~= botId then return end

			local enemies = LivingHeroesOf(OpponentSide(botId).id)
			if #enemies == 0 then break end

			local best = nil
			for _, hero in ipairs(LivingHeroesOf(botId)) do
				if not resolved[hero.uid] then
					local plan = PlanFor(hero, enemies)
					if plan and (not best or plan.score > best.score) then
						best = plan
					end
				end
			end

			if not best then break end

			if best.position ~= best.hero.position then
				MatchManager.MoveHero(nil, best.hero.uid, best.position)
				task.wait(BOT_ACTION_DELAY)
			end

			if not match or match.phase ~= "battle" or match.turn.ownerId ~= botId then return end

			if best.target and best.target.isAlive and best.hero.isAlive then
				MatchManager.AttackHero(nil, best.hero.uid, best.target.uid)
				task.wait(BOT_ACTION_DELAY)
			else
				-- só reposicionou: encerra o herói pra não reavaliá-lo em loop
				resolved[best.hero.uid] = true
			end
		end

		if match and match.phase == "battle" and match.turn.ownerId == botId then
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
		Broadcast()
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

	if SideOf(ownerId).isBot then
		BotPlayTurn(ownerId)
	end
end

function MatchManager.EndTurn(player)
	if not match or match.phase ~= "battle" then return end
	if match.busy then return end

	local currentSide = SideOf(match.turn.ownerId)
	if player and currentSide.player ~= player then return end

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
		Broadcast()
		return
	end

	local wasStarter = (endingOwner == match.starterId)
	local nextOwner = OpponentSide(endingOwner).id
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

	if player and SideOf(match.turn.ownerId).player ~= player then return false end
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
		Broadcast()
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

-- Ordem de escolha do bot no draft: tanque que se cura, curandeira, e depois
-- os que fazem mais estrago. Melhor que sortear — o time sai com uma função
-- definida em vez de três heróis aleatórios.
local BOT_DRAFT_PRIORITY = { 6, 8, 4, 7, 1, 9, 5, 2, 3 }

local function BotPickHeroId(available)
	for _, dataId in ipairs(BOT_DRAFT_PRIORITY) do
		if table.find(available, dataId) then return dataId end
	end
	return available[1]
end

-- Tanque no meio da fileira (trava a passagem), ranged nas pontas (fica longe
-- do aperto), o resto preenche do centro pra fora.
local function BotPickHex(data, zone, free)
	local center = (#zone + 1) / 2

	local function offsetFromCenter(hexId)
		local index = table.find(zone, hexId)
		return index and math.abs(index - center) or 0
	end

	table.sort(free, function(a, b)
		if data.ability == RANGED then
			return offsetFromCenter(a) > offsetFromCenter(b)
		end
		return offsetFromCenter(a) < offsetFromCenter(b)
	end)

	return free[1]
end

local function AllPlaced()
	for _, side in ipairs(match.sides) do
		if side.placedCount < GameConfig.HEROES_PER_PLAYER then return false end
	end
	return true
end

function AdvancePlacement()
	if AllPlaced() then
		match.phase = "battle"
		print("MatchManager: draft concluído, combate começou.")
		BeginTurn(match.starterId, 1)
		return
	end

	-- passa a vez, mas pula quem já completou o time
	local nextIndex = (match.placementSide == 1) and 2 or 1
	if match.sides[nextIndex].placedCount >= GameConfig.HEROES_PER_PLAYER then
		nextIndex = match.placementSide
	end
	match.placementSide = nextIndex

	Broadcast()

	if match.sides[nextIndex].isBot then
		task.delay(GameConfig.BOT_PLACE_DELAY, BotPlaceOne)
	end
end

function BotPlaceOne()
	if not match or match.phase ~= "placement" then return end

	local side = match.sides[match.placementSide]
	if not side.isBot then return end

	local available = AvailableHeroIds()
	local free = FreeHexesIn(side.zone)

	if #available > 0 and #free > 0 then
		local dataId = BotPickHeroId(available)
		local hexId = BotPickHex(HeroData.GetById(dataId), side.zone, free)
		CreateHero(dataId, side.id, hexId)
		match.usedHeroIds[dataId] = true
		side.placedCount += 1
	end

	AdvancePlacement()
end

function MatchManager.PlaceHero(player, dataId, hexId)
	if not match or match.phase ~= "placement" then return end

	local side = match.sides[match.placementSide]
	if side.player ~= player then return end
	if side.placedCount >= GameConfig.HEROES_PER_PLAYER then return end
	if type(dataId) ~= "number" or type(hexId) ~= "string" then return end
	if not HeroData.GetById(dataId) then return end
	if match.usedHeroIds[dataId] then return end
	if not table.find(side.zone, hexId) then return end
	if not HexGrid.IsFree(hexId) then return end

	CreateHero(dataId, side.id, hexId)
	match.usedHeroIds[dataId] = true
	side.placedCount += 1

	AdvancePlacement()
end

-- ===================== CICLO DA PARTIDA =====================
-- playerTwo == nil monta uma partida contra o bot
function MatchManager.StartMatch(playerOne, playerTwo)
	if not playerOne then return end

	-- regenera o grid pra zerar ocupação (essencial na revanche)
	HexGrid.Generate()

	local sides = {
		{
			index = 1,
			id = tostring(playerOne.UserId),
			player = playerOne,
			isBot = false,
			zone = BuildDeployZone(DEPLOY_ZONES[1]),
			placedCount = 0,
		},
		{
			index = 2,
			id = playerTwo and tostring(playerTwo.UserId) or BOT_ID,
			player = playerTwo,
			isBot = playerTwo == nil,
			zone = BuildDeployZone(DEPLOY_ZONES[2]),
			placedCount = 0,
		},
	}

	local sideIndexById = {}
	for index, side in ipairs(sides) do
		sideIndexById[side.id] = index
	end

	match = {
		sides = sides,
		sideIndexById = sideIndexById,
		vsBot = playerTwo == nil,
		phase = "placement",
		heroes = {},
		usedHeroIds = {},
		placementSide = 1, -- lado 1 escolhe primeiro: 1,2,1,2...
		starterId = sides[1].id,
		turn = nil,
		winner = nil,
		busy = false,
	}

	HeroView.ClearAll()
	HeroView.PlayGlobalSound("MatchStart")

	Broadcast()
	print(("MatchManager: draft iniciado (%s)."):format(playerTwo and "PvP" or "vs bot"))
end

function MatchManager.Replay(player)
	if not match or match.phase ~= "finished" then return end
	if not SideOfPlayer(player) then return end

	local playerOne = match.sides[1].player
	local playerTwo = match.sides[2].player

	-- se o dono do lado 1 saiu, quem sobrou reassume como lado 1
	if not playerOne then
		playerOne, playerTwo = playerTwo, nil
	end
	if not playerOne then return end

	MatchManager.StartMatch(playerOne, playerTwo)
end

local function EndMatch()
	HeroView.ClearAll()

	local board = Workspace:FindFirstChild("Board")
	if board then board:Destroy() end

	for _, side in ipairs(match.sides) do
		if side.player then
			MatchUpdate:FireClient(side.player, { phase = "lobby" })
		end
	end

	match = nil
end

function MatchManager.LeaveMatch(player)
	if not match or not SideOfPlayer(player) then return end
	EndMatch()
end

-- Um jogador caiu no meio da partida: encerra pra todo mundo em vez de deixar
-- o outro preso esperando um turno que nunca vem.
function MatchManager.HandlePlayerLeft(player)
	if not match then return end

	local side = SideOfPlayer(player)
	if not side then return end

	side.player = nil
	EndMatch()
end

function MatchManager.IsActive()
	return match ~= nil
end

function MatchManager.GetMatch()
	return match
end

return MatchManager
