--[[
	MatchManager.lua
	ModuleScript — ServerScriptService/Modules/MatchManager

	Regras da partida: draft alternado, turnos, combate, skills e o bot.

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
local Skills = require(ServerScriptService.Modules.Skills)
local HeroView = require(ServerScriptService.Modules.HeroView)
local BoardSpawner = require(ServerScriptService.Modules.BoardSpawner)
local LeaderboardService = require(ServerScriptService.Modules.LeaderboardService)
local ProgressionService = require(ServerScriptService.Modules.ProgressionService)

local MatchUpdate = ReplicatedStorage.Remotes.MatchUpdate
local BoardReady = ReplicatedStorage.Remotes.BoardReady

local MatchManager = {}

-- ===== AJUSTE FINO =====
local BOT_ACTION_DELAY = 0.7
local COUNTER_ATTACK_DELAY = 0.4

local BOT_ID = "BOT"

-- ===== REGISTRO DE PARTIDAS =====
local matches = {} -- [matchId] = match
local matchBySlot = {} -- [slot] = match
local nextMatchId = 0

-- declaradas cedo porque se chamam entre si
local BeginTurn, BotPlayTurn, BotPlaceOne, AdvancePlacement, CheckGameOver

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
local function SideOf(match, ownerId)
	local index = match.sideIndexById[ownerId]
	return index and match.sides[index] or nil
end

local function OpponentSide(match, ownerId)
	local index = match.sideIndexById[ownerId]
	return match.sides[index == 1 and 2 or 1]
end

local function SideOfPlayer(match, player)
	for _, side in ipairs(match.sides) do
		if side.player == player then return side end
	end
	return nil
end

-- Ponte entre o RemoteEvent (que só traz o Player) e a partida dele
local function MatchOfPlayer(player)
	if not player then return nil end
	for _, match in pairs(matches) do
		if SideOfPlayer(match, player) then return match end
	end
	return nil
end

-- ===================== OCUPAÇÃO =====================
-- Mora na partida, não no HexGrid: duas partidas usam as MESMAS casas (A1, B2...)
-- e com ocupação global uma bloquearia a outra.
local function GetHeroAt(match, hexId)
	return match.occupied[hexId]
end

local function IsFree(match, hexId)
	return HexGrid.Exists(hexId) and match.occupied[hexId] == nil
end

-- fecha sobre a partida: é o que vai pro ComputeReach/FindPath do HexGrid
local function FreeChecker(match)
	return function(hexId)
		return IsFree(match, hexId)
	end
end

-- ===================== CONSULTAS =====================
local function GetAlliesInRange(match, hero, range)
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

local function LivingHeroesOf(match, ownerId)
	local result = {}
	for _, hero in pairs(match.heroes) do
		if hero.ownerId == ownerId and hero.isAlive then
			table.insert(result, hero)
		end
	end
	return result
end

-- ===================== SKILLS =====================
local function TriggerSkills(match, hero, triggerName, target, isCounterAttack, ctx)
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
			}, { __index = match.skillApi })

			local ok, err = pcall(skill.apply, scope)
			if not ok then
				warn(("Skill %s falhou em %s: %s"):format(key, hero.name, tostring(err)))
			end
			HeroView.UpdateStats(hero)
		end
	end
end

-- ===================== DANO / CURA =====================
local ApplyDamage, KillHero

function KillHero(match, hero, attacker)
	hero.isAlive = false

	-- Destaque do finalizador: fica guardado até o próximo Broadcast e vai UMA
	-- vez só. Morte sem autor (veneno, Morte Súbita) chega aqui com attacker nil
	-- e não gera destaque — não teria de quem mostrar o retrato.
	if attacker and attacker ~= hero then
		match.finisher = {
			dataId = attacker.dataId,
			name = attacker.name,
			ownerId = attacker.ownerId,
			sideIndex = attacker.sideIndex,
			victim = hero.name,
		}
	end

	-- a casa NÃO é liberada: o túmulo continua ocupando o hex
	TriggerSkills(match, hero, "onDie")

	HeroView.PlayAnimation(hero, "die")
	HeroView.Destroy(hero)
	HeroView.CreateGrave(hero)
end

function ApplyDamage(match, hero, amount, attacker, isCounterAttack)
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
	HeroView.UpdateStats(hero)
	HeroView.PlayAnimation(hero, "hit")
	HeroView.Say(hero, "-" .. tostring(amount), "damage")

	if hero.currentHp <= 0 then
		KillHero(match, hero, attacker)
	else
		TriggerSkills(match, hero, "onDamage", attacker, isCounterAttack)
	end
end

local function Heal(match, hero, amount)
	if not hero.isAlive then return end
	hero.currentHp = math.min(hero.currentHp + amount, hero.maxHp)
	HeroView.UpdateStats(hero)
	HeroView.PlayHealSound(hero)
	HeroView.Say(hero, "+" .. tostring(amount), "heal")
end

local function IncreaseAttack(hero, amount)
	hero.attack += amount
	HeroView.UpdateStats(hero)
	HeroView.Say(hero, (amount > 0 and "+" or "") .. tostring(amount) .. " ATK", amount > 0 and "buff" or "debuff")
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
	HeroView.UpdateStats(hero)
end

local function ClearStatusEffects(hero)
	hero.statusEffects = {}
	HeroView.UpdateStats(hero)
end

-- Roda no fim do turno do próprio herói: aplica o efeito e decrementa
local function ProcessStatusEffects(match, hero)
	local remaining = {}

	for _, effect in ipairs(hero.statusEffects) do
		if effect.damagePerTurn then
			ApplyDamage(match, hero, effect.damagePerTurn, nil, false)
		end
		if effect.duration > 1 then
			effect.duration -= 1
			table.insert(remaining, effect)
		end
	end

	hero.statusEffects = remaining
	HeroView.UpdateStats(hero)
end

-- ===================== MOVIMENTO =====================
-- Reposiciona sem bookkeeping de turno — usado pelo empurrão do rage
local function ForceMove(match, hero, hexId)
	if not IsFree(match, hexId) then return false end

	match.occupied[hero.position] = nil
	hero.position = hexId
	match.occupied[hexId] = hero
	HeroView.SetPosition(hero, hexId)
	return true
end

-- ===================== API DAS SKILLS =====================
-- Uma API por partida: as closures já sabem em qual tabuleiro mexer, então a
-- skill continua escrita como antes (ctx.api.ApplyDamage(...)) sem saber que
-- existem outras partidas rodando.
local function BuildSkillApi(match)
	return {
		ApplyDamage = function(hero, amount, attacker, isCounterAttack)
			ApplyDamage(match, hero, amount, attacker, isCounterAttack)
		end,
		Heal = function(hero, amount) Heal(match, hero, amount) end,
		IncreaseAttack = IncreaseAttack,
		GetHeroAt = function(hexId) return GetHeroAt(match, hexId) end,
		GetAlliesInRange = function(hero, range) return GetAlliesInRange(match, hero, range) end,
		GetLineBeyond = HexGrid.GetLineBeyond,
		IsFree = function(hexId) return IsFree(match, hexId) end,
		ForceMove = function(hero, hexId) return ForceMove(match, hero, hexId) end,
		FindStatusEffect = FindStatusEffect,
		ApplyStatusEffect = ApplyStatusEffect,
		ClearStatusEffects = ClearStatusEffects,
		PlaySkillSound = function(key) HeroView.PlaySkillSound(key, match.view) end,
		Say = HeroView.Say,
	}
end

-- ===================== SNAPSHOT =====================
local function TurnSecondsLeft(match)
	if not match.turn or GameConfig.TURN_TIME_LIMIT <= 0 then return nil end
	local elapsed = os.clock() - match.turn.startedAt
	return math.max(0, math.floor(GameConfig.TURN_TIME_LIMIT - elapsed))
end

-- O estado é montado por espectador: quem olha precisa saber o que é dele,
-- não quem é "o player" e quem é "o bot".
local function Snapshot(match, viewerId)
	local viewerSide = SideOf(match, viewerId)
	local opponent = OpponentSide(match, viewerId)

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
			-- 1 = azul, 2 = vermelho. Vai junto pra UI pintar o retrato com a
			-- MESMA cor do anel embaixo do herói no tabuleiro: em PvP quem joga
			-- de lado 2 é dono dos vermelhos, e colorir por "é meu?" mentiria.
			sideIndex = hero.sideIndex,
			hasMoved = match.turn and match.turn.moved[hero.uid] or false,
			hasAttacked = match.turn and match.turn.attacked[hero.uid] or false,
		})
	end

	-- `match.heroes` é dicionário: a ordem de pairs() muda entre snapshots. Isso
	-- nunca importou pra pintar o tabuleiro (tudo é lido por hexId), mas a coluna
	-- de retratos da UI segue esta lista — sem ordenar, os retratos trocavam de
	-- lugar sozinhos a cada atualização. O uid é matchId_dono_heroi, então
	-- ordenar por ele agrupa por jogador e mantém a ordem fixa a partida inteira.
	table.sort(heroes, function(a, b) return a.uid < b.uid end)

	local winner = nil
	if match.winner == "draw" then
		winner = "draw"
	elseif match.winner then
		winner = (match.winner == viewerId) and "win" or "loss"
	end

	-- Vai como ARRAY, não como dicionário {[id] = true}: dicionário com chave
	-- numérica atravessa o RemoteEvent de forma inconsistente (às vezes chega
	-- com chave string), e era por isso que o herói escolhido pelo adversário
	-- nem sempre aparecia marcado como usado no cliente.
	local usedHeroIds = {}
	for dataId in pairs(match.usedHeroIds) do
		table.insert(usedHeroIds, dataId)
	end
	table.sort(usedHeroIds)

	-- `isMine` é resolvido por espectador, igual ao resto do snapshot: o cliente
	-- pinta o destaque com a cor do lado e precisa saber se foi o time dele que
	-- abateu ou que apanhou.
	local finisher = nil
	if match.finisher then
		finisher = {
			dataId = match.finisher.dataId,
			name = match.finisher.name,
			victim = match.finisher.victim,
			sideIndex = match.finisher.sideIndex,
			isMine = match.finisher.ownerId == viewerId,
		}
	end

	return {
		phase = match.phase,
		deployZone = viewerSide.zone,
		placedCount = viewerSide.placedCount,
		opponentPlacedCount = opponent.placedCount,
		isMyPlacement = match.sides[match.placementSide].id == viewerId,
		heroesPerPlayer = GameConfig.HEROES_PER_PLAYER,
		usedHeroIds = usedHeroIds,
		heroes = heroes,
		turnNumber = match.turn and match.turn.number or 0,
		isMyTurn = match.turn and match.turn.ownerId == viewerId or false,
		turnSecondsLeft = TurnSecondsLeft(match),
		turnTimeLimit = GameConfig.TURN_TIME_LIMIT,
		suddenDeath = match.turn and match.turn.number >= GameConfig.SUDDEN_DEATH_START_TURN or false,

		-- O contra-ataque é UM por turno, valendo pros dois lados: quem defende
		-- revida no primeiro golpe do turno e ninguém mais revida até o turno
		-- virar. O cliente mostra isso como um selo aceso/apagado.
		counterAttackUsed = match.turn and match.turn.counterAttack or false,

		winner = winner,
		message = match.message,
		finisher = finisher,
		vsBot = match.vsBot,
		opponentName = opponent.player and opponent.player.DisplayName or "Bot",

		-- o cliente pinta as casas por aqui: procurar "Board" pelo nome no
		-- Workspace acharia o tabuleiro da partida errada
		boardFolder = match.boardFolder,
	}
end

local function Broadcast(match, message)
	match.message = message
	for _, side in ipairs(match.sides) do
		if side.player then
			MatchUpdate:FireClient(side.player, Snapshot(match, side.id))
		end
	end
	match.message = nil

	-- o destaque é evento, não estado: sai num snapshot só, senão a animação
	-- dispararia de novo a cada atualização até o fim do turno
	match.finisher = nil
end

-- ===================== HERÓIS =====================
local function CreateHero(match, dataId, ownerId, hexId)
	local data = HeroData.GetById(dataId)
	if not data then return nil end

	local hero = {
		-- o matchId entra no uid porque o lado bot se chama "BOT" nas duas
		-- partidas: sem prefixo, dois jogos contra o bot colidiriam
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
		position = hexId,
		isAlive = true,
		statusEffects = {},
		firstAttack = false,
		firstPunchApplied = false,
		view = match.view,
	}

	match.heroes[hero.uid] = hero
	match.occupied[hexId] = hero
	HeroView.Create(hero)
	HeroView.PlayPlaceSound(match.view)
	return hero
end

-- ===================== XP =====================
-- O UpdateAsync do DataStore cede, e o fim de partida roda no meio da resolução
-- de um ataque: task.spawn pra não segurar o Broadcast do golpe final.
local function AwardXp(match, side, result, survivors)
	if not side or side.isBot or not side.player then return end
	task.spawn(ProgressionService.AwardMatchXp, side.player, result, survivors, match.vsBot)
end

-- ===================== FIM DE JOGO =====================
function CheckGameOver(match)
	local aliveOne = #LivingHeroesOf(match, match.sides[1].id)
	local aliveTwo = #LivingHeroesOf(match, match.sides[2].id)

	if aliveOne > 0 and aliveTwo > 0 then return false end

	match.phase = "finished"
	if aliveOne == 0 and aliveTwo == 0 then
		match.winner = "draw"
		AwardXp(match, match.sides[1], "draw")
		AwardXp(match, match.sides[2], "draw")
	else
		local oneWon = aliveTwo == 0
		local winningSide = oneWon and match.sides[1] or match.sides[2]
		local losingSide = oneWon and match.sides[2] or match.sides[1]
		local survivors = oneWon and aliveOne or aliveTwo

		match.winner = winningSide.id

		-- ranking global conta vitória em qualquer modo, menos do próprio bot
		if not winningSide.isBot then
			LeaderboardService.RecordWin(tonumber(winningSide.id))
		end

		-- a vitória paga pela margem (heróis vivos), a derrota paga fixo
		AwardXp(match, winningSide, "win", survivors)
		AwardXp(match, losingSide, "loss")
	end
	return true
end

-- ===================== COMBATE =====================
local function PerformAttack(match, attacker, target, isCounterAttack)
	HeroView.PlayAnimation(attacker, "attack")
	HeroView.PlayAttackSound(attacker)
	if attacker.attackRange >= 2 then
		HeroView.ShowRangedAttack(attacker, target)
	end

	local ctx = { damageApplied = false }
	TriggerSkills(match, attacker, isCounterAttack and "onCounterAttack" or "onAttack",
		target, isCounterAttack, ctx)

	if not ctx.damageApplied and target.isAlive then
		ApplyDamage(match, target, attacker.attack, attacker, isCounterAttack)
	end

	attacker.firstAttack = true
	HeroView.UpdateStats(attacker)
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

local function AlliesAdjacentTo(match, hero, position)
	local list = {}
	for _, neighbor in ipairs(HexGrid.GetNeighbors(position)) do
		local occupant = GetHeroAt(match, neighbor.id)
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
local function ReachFrom(match, hero, fromPos, range)
	local isFree = function(hexId)
		if hexId == hero.position or hexId == fromPos then return true end
		return IsFree(match, hexId)
	end
	return HexGrid.ComputeReach(fromPos, range, isFree)
end

-- Um Taunt inimigo adjacente trava o ataque em qualquer outro alvo
local function TauntBlocks(match, attacker, target, fromPos)
	if target.ability == TAUNT then return false end

	for _, neighbor in ipairs(HexGrid.GetNeighbors(fromPos)) do
		local occupant = GetHeroAt(match, neighbor.id)
		if occupant and occupant.isAlive
			and occupant.ownerId ~= attacker.ownerId
			and occupant.ability == TAUNT then
			return true
		end
	end
	return false
end

local function EstimateDamage(match, attacker, target, fromPos)
	local damage = attacker.attack

	-- trustInTeam recalcula no onMove: prevê o ataque já pós-movimento
	if HasSkill(attacker, "trustInTeam") then
		local buffed = attacker.attack > attacker.baseAttack
		local willHaveAlly = #AlliesAdjacentTo(match, attacker, fromPos) > 0
		if willHaveAlly and not buffed then
			damage += 1
		elseif not willHaveAlly and buffed then
			damage -= 1
		end
	end

	if HasSkill(attacker, "aloneIsBetter") and #AlliesAdjacentTo(match, target, target.position) == 0 then
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
		if not (behind and IsFree(match, behind)) then damage += 1 end
	end

	return damage
end

-- Inimigos extras que o Blade acerta na mesma linha
local function LineHits(match, attacker, target, fromPos)
	if not HasSkill(attacker, "beyondFront") then return 0 end

	local hits = 0
	for _, hexId in ipairs(HexGrid.GetLineBeyond(fromPos, target.position, 2)) do
		local other = GetHeroAt(match, hexId)
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

local function ScoreAttack(match, attacker, target, fromPos)
	if TauntBlocks(match, attacker, target, fromPos) then return nil end

	local damage = EstimateDamage(match, attacker, target, fromPos)
	local score = damage * 10

	if damage >= target.currentHp then
		score += 120 + ThreatScore(target) * 4 -- abater é sempre a prioridade
	else
		score += (target.maxHp - target.currentHp) * 2 -- concentra fogo no ferido
		score += ThreatScore(target) * 2
	end

	score += LineHits(match, attacker, target, fromPos) * 30

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
		for _, ally in ipairs(AlliesAdjacentTo(match, attacker, fromPos)) do
			if #ally.statusEffects > 0 then score += 25 end
		end
	end

	score -= CounterDamage(attacker, target, fromPos, damage) * 7

	return score
end

-- Valor de ocupar uma casa, mesmo sem atacar neste turno
local function ScorePosition(match, hero, fromPos, enemies)
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
		score += #AlliesAdjacentTo(match, hero, fromPos) * 10
	end

	-- Elaria cura e limpa vizinhos: cola em quem precisa
	if HasSkill(hero, "health") or HasSkill(hero, "clean") then
		for _, ally in ipairs(AlliesAdjacentTo(match, hero, fromPos)) do
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
			if #AlliesAdjacentTo(match, enemy, enemy.position) == 0
				and HexGrid.Distance(fromPos, enemy.position) <= hero.attackRange then
				score += 20
			end
		end
	end

	return score
end

-- Melhor jogada de um herói: para onde ir e quem bater
local function PlanFor(match, hero, enemies)
	local canMove = not match.turn.moved[hero.uid] and not match.turn.attacked[hero.uid]
	local canAttack = not match.turn.attacked[hero.uid]
	if not canMove and not canAttack then return nil end

	local positions = { [hero.position] = true }
	if canMove then
		for hexId in pairs(HexGrid.ComputeReach(hero.position, hero.moveRange, FreeChecker(match))) do
			if IsFree(match, hexId) then positions[hexId] = true end
		end
	end

	local best = nil
	for fromPos in pairs(positions) do
		local stayBonus = (fromPos == hero.position) and 2 or 0 -- desempata a favor de ficar
		local positional = ScorePosition(match, hero, fromPos, enemies) + stayBonus

		local bestTarget, bestAttackScore = nil, nil
		if canAttack then
			local reach = ReachFrom(match, hero, fromPos, hero.attackRange)
			for _, enemy in ipairs(enemies) do
				if reach[enemy.position] then
					local attackScore = ScoreAttack(match, hero, enemy, fromPos)
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
local function MatchIsLive(match)
	return matches[match.id] ~= nil
end

function BotPlayTurn(match, botId)
	task.spawn(function()
		task.wait(BOT_ACTION_DELAY)

		-- age sempre com quem tem a melhor jogada disponível; o tabuleiro muda
		-- a cada movimento/abate, então o plano é refeito a cada iteração
		local resolved = {}

		for _ = 1, GameConfig.HEROES_PER_PLAYER * 2 do
			if not MatchIsLive(match) or match.phase ~= "battle" or match.turn.ownerId ~= botId then return end

			local enemies = LivingHeroesOf(match, OpponentSide(match, botId).id)
			if #enemies == 0 then break end

			local best = nil
			for _, hero in ipairs(LivingHeroesOf(match, botId)) do
				if not resolved[hero.uid] then
					local plan = PlanFor(match, hero, enemies)
					if plan and (not best or plan.score > best.score) then
						best = plan
					end
				end
			end

			if not best then break end

			if best.position ~= best.hero.position then
				MatchManager.MoveHero(nil, best.hero.uid, best.position, match)
				task.wait(BOT_ACTION_DELAY)
			end

			if not MatchIsLive(match) or match.phase ~= "battle" or match.turn.ownerId ~= botId then return end

			if best.target and best.target.isAlive and best.hero.isAlive then
				MatchManager.AttackHero(nil, best.hero.uid, best.target.uid, match)
				task.wait(BOT_ACTION_DELAY)
			else
				-- só reposicionou: encerra o herói pra não reavaliá-lo em loop
				resolved[best.hero.uid] = true
			end
		end

		if MatchIsLive(match) and match.phase == "battle" and match.turn.ownerId == botId then
			MatchManager.EndTurn(nil, match)
		end
	end)
end

function BeginTurn(match, ownerId, number)
	match.turnToken += 1
	local token = match.turnToken

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
			TriggerSkills(match, hero, "onTurnStart")
		end
	end

	local message = nil
	if number == GameConfig.SUDDEN_DEATH_WARNING_TURN then
		message = "⚠ Morte Súbita se aproxima!"
	end

	if number >= GameConfig.SUDDEN_DEATH_START_TURN then
		for _, hero in pairs(match.heroes) do
			if hero.isAlive then
				ApplyDamage(match, hero, GameConfig.SUDDEN_DEATH_DAMAGE, nil, false)
			end
		end
		message = "☠ Morte Súbita: todos perdem 1 de vida!"
	end

	if CheckGameOver(match) then
		Broadcast(match)
		return
	end

	Broadcast(match, message)

	-- cronômetro: encerra o turno sozinho quando o tempo acaba
	if GameConfig.TURN_TIME_LIMIT > 0 then
		task.delay(GameConfig.TURN_TIME_LIMIT, function()
			if not (MatchIsLive(match) and match.turn and match.turn.token == token and match.phase == "battle") then return end

			-- espera uma animação em curso terminar, senão o EndTurn seria recusado
			local waited = 0
			while MatchIsLive(match) and match.busy and waited < 3 do
				task.wait(0.1)
				waited += 0.1
			end

			if MatchIsLive(match) and match.turn and match.turn.token == token and match.phase == "battle" then
				Broadcast(match, "⏱ Tempo esgotado!")
				MatchManager.EndTurn(nil, match)
			end
		end)
	end

	if SideOf(match, ownerId).isBot then
		BotPlayTurn(match, ownerId)
	end
end

-- `match` explícito nas chamadas internas (bot/cronômetro); vindo do cliente,
-- é resolvido pelo Player.
function MatchManager.EndTurn(player, match)
	match = match or MatchOfPlayer(player)
	if not match or match.phase ~= "battle" then return end
	if match.busy then return end

	local currentSide = SideOf(match, match.turn.ownerId)
	if player and currentSide.player ~= player then return end

	-- fim de turno de quem está encerrando: veneno primeiro, depois skills
	local endingOwner = match.turn.ownerId
	for _, hero in pairs(match.heroes) do
		if hero.ownerId == endingOwner and hero.isAlive then
			ProcessStatusEffects(match, hero)
			if hero.isAlive then
				TriggerSkills(match, hero, "onTurnEnd")
			end
		end
	end

	if CheckGameOver(match) then
		Broadcast(match)
		return
	end

	local wasStarter = (endingOwner == match.starterId)
	local nextOwner = OpponentSide(match, endingOwner).id
	local nextNumber = match.turn.number + (wasStarter and 0 or 1)

	BeginTurn(match, nextOwner, nextNumber)
end

-- ===================== AÇÕES =====================
-- player == nil significa ação do bot (já validada internamente)
local function AuthorizeAction(match, player, hero)
	if not match or match.phase ~= "battle" then return false end
	if match.busy then return false end
	if not hero or not hero.isAlive then return false end
	if hero.ownerId ~= match.turn.ownerId then return false end

	if player and SideOf(match, match.turn.ownerId).player ~= player then return false end
	return true
end

function MatchManager.MoveHero(player, heroUid, hexId, match)
	match = match or MatchOfPlayer(player)
	local hero = match and match.heroes[heroUid]
	if not AuthorizeAction(match, player, hero) then return end

	-- canMoveHero: não pode ter movido NEM atacado neste turno
	if match.turn.moved[heroUid] or match.turn.attacked[heroUid] then return end
	if type(hexId) ~= "string" or not HexGrid.Exists(hexId) then return end
	if not IsFree(match, hexId) then return end

	-- FindPath já garante alcance e caminho livre: substitui o ComputeReach
	local path = HexGrid.FindPath(hero.position, hexId, hero.moveRange, FreeChecker(match))
	if not path then return end

	-- o estado lógico muda na hora; a caminhada é só visual
	match.occupied[hero.position] = nil
	hero.position = hexId
	match.occupied[hexId] = hero
	match.turn.moved[heroUid] = true

	-- onMove dispara pros heróis dos dois lados (igual ao Phaser)
	for _, other in pairs(match.heroes) do
		if other.isAlive then
			TriggerSkills(match, other, "onMove")
		end
	end

	Broadcast(match)

	-- caminha casa por casa; busy trava ações concorrentes durante o passeio
	match.busy = true
	HeroView.WalkPath(hero, path)
	match.busy = false

	Broadcast(match)
end

function MatchManager.AttackHero(player, attackerUid, targetUid, match)
	match = match or MatchOfPlayer(player)
	local attacker = match and match.heroes[attackerUid]
	local target = match and match.heroes[targetUid]
	if not AuthorizeAction(match, player, attacker) then return end
	if not target or not target.isAlive then return end
	if target.ownerId == attacker.ownerId then return end
	if match.turn.attacked[attackerUid] then return end

	-- alcance + caminho livre até o alvo
	local reach = HexGrid.ComputeReach(attacker.position, attacker.attackRange, FreeChecker(match))
	if not reach[target.position] then return end

	-- Taunt: inimigo com Taunt adjacente ao atacante trava o ataque em outro alvo
	if target.ability ~= GameConfig.ABILITIES.TAUNT then
		for _, neighbor in ipairs(HexGrid.GetNeighbors(attacker.position)) do
			local occupant = GetHeroAt(match, neighbor.id)
			if occupant and occupant.isAlive
				and occupant.ownerId ~= attacker.ownerId
				and occupant.ability == GameConfig.ABILITIES.TAUNT then
				Broadcast(match, ("%s está bloqueado por Taunt de %s"):format(attacker.name, occupant.name))
				return
			end
		end
	end

	PerformAttack(match, attacker, target, false)
	match.turn.attacked[attackerUid] = true

	-- contra-ataque: uma vez por turno, se o alvo sobreviveu e alcança o atacante
	if not match.turn.counterAttack and target.isAlive and attacker.isAlive then
		if HexGrid.Distance(target.position, attacker.position) <= target.attackRange then
			match.turn.counterAttack = true

			match.busy = true
			task.wait(COUNTER_ATTACK_DELAY)
			match.busy = false

			PerformAttack(match, target, attacker, true)
		end
	end

	if CheckGameOver(match) then
		Broadcast(match)
		return
	end

	Broadcast(match)
end

-- ===================== DRAFT ALTERNADO (1,2,1,2) =====================
local function AvailableHeroIds(match)
	local available = {}
	for _, data in ipairs(HeroData.CATALOG) do
		if not match.usedHeroIds[data.id] then
			table.insert(available, data.id)
		end
	end
	return available
end

local function FreeHexesIn(match, zone)
	local free = {}
	for _, hexId in ipairs(zone) do
		if IsFree(match, hexId) then
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

local function AllPlaced(match)
	for _, side in ipairs(match.sides) do
		if side.placedCount < GameConfig.HEROES_PER_PLAYER then return false end
	end
	return true
end

function AdvancePlacement(match)
	if AllPlaced(match) then
		match.phase = "battle"
		BeginTurn(match, match.starterId, 1)
		return
	end

	-- passa a vez, mas pula quem já completou o time
	local nextIndex = (match.placementSide == 1) and 2 or 1
	if match.sides[nextIndex].placedCount >= GameConfig.HEROES_PER_PLAYER then
		nextIndex = match.placementSide
	end
	match.placementSide = nextIndex

	Broadcast(match)

	if match.sides[nextIndex].isBot then
		task.delay(GameConfig.BOT_PLACE_DELAY, function()
			BotPlaceOne(match)
		end)
	end
end

function BotPlaceOne(match)
	if not MatchIsLive(match) or match.phase ~= "placement" then return end

	local side = match.sides[match.placementSide]
	if not side.isBot then return end

	local available = AvailableHeroIds(match)
	local free = FreeHexesIn(match, side.zone)

	if #available > 0 and #free > 0 then
		local dataId = BotPickHeroId(available)
		local hexId = BotPickHex(HeroData.GetById(dataId), side.zone, free)
		CreateHero(match, dataId, side.id, hexId)
		match.usedHeroIds[dataId] = true
		side.placedCount += 1
	end

	AdvancePlacement(match)
end

function MatchManager.PlaceHero(player, dataId, hexId)
	local match = MatchOfPlayer(player)
	if not match or match.phase ~= "placement" then return end

	local side = match.sides[match.placementSide]
	if side.player ~= player then return end
	if side.placedCount >= GameConfig.HEROES_PER_PLAYER then return end
	if type(dataId) ~= "number" or type(hexId) ~= "string" then return end
	if not HeroData.GetById(dataId) then return end
	if match.usedHeroIds[dataId] then return end
	if not table.find(side.zone, hexId) then return end
	if not IsFree(match, hexId) then return end

	CreateHero(match, dataId, side.id, hexId)
	match.usedHeroIds[dataId] = true
	side.placedCount += 1

	AdvancePlacement(match)
end

-- ===================== STREAMING =====================
-- Com Workspace.StreamingEnabled, o cliente só recebe as regiões perto do
-- personagem dele. A arena fica a centenas de studs do lobby, então no primeiro
-- instante da partida o tabuleiro AINDA NÃO EXISTE no cliente — e o
-- `boardFolder` que viaja no snapshot é uma REFERÊNCIA de instância: referência
-- para algo que não foi transmitido chega `nil` do outro lado.
--
-- É a causa de raiz de uma família de remendos espalhados pelo cliente ("o Board
-- é replicado de forma assíncrona", a zona de largada que às vezes não ficava
-- verde, o retry do selectHero). Pedir o streaming ANTES de avisar o cliente
-- resolve na origem; os remendos continuam lá como rede de segurança para
-- quando o pedido estourar o prazo.
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

	-- Espera os dois lados, mas nunca além do prazo: entrar com o tabuleiro meio
	-- carregado é ruim; travar a partida esperando é pior.
	local waited = 0
	while pending > 0 and waited < STREAM_TIMEOUT + 1 do
		task.wait(0.1)
		waited += 0.1
	end
end

-- ===================== SLOTS DE ARENA =====================
local function AllocateSlot()
	for slot = 1, GameConfig.MAX_SIMULTANEOUS_MATCHES do
		if not matchBySlot[slot] then return slot end
	end
	return nil
end

function MatchManager.HasFreeSlot()
	return AllocateSlot() ~= nil
end

function MatchManager.IsInMatch(player)
	return MatchOfPlayer(player) ~= nil
end

-- ===================== CICLO DA PARTIDA =====================
-- playerTwo == nil monta uma partida contra o bot.
-- `slot` só vem preenchido na revanche, pra reaproveitar a mesma arena e não
-- teletransportar a câmera de quem já está sentado ali.
function MatchManager.StartMatch(playerOne, playerTwo, slot)
	if not playerOne then return false end

	slot = slot or AllocateSlot()
	if not slot then return false end

	nextMatchId += 1
	local matchId = nextMatchId
	local origin = GameConfig.ArenaOrigin(slot)

	local players = { playerOne }
	if playerTwo then table.insert(players, playerTwo) end

	local boardFolder = BoardSpawner.SpawnBoard(slot, playerTwo == nil)

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

	local match = {
		id = matchId,
		slot = slot,
		origin = origin,
		boardFolder = boardFolder,
		view = HeroView.CreateView(matchId, origin, players),
		sides = sides,
		sideIndexById = sideIndexById,
		vsBot = playerTwo == nil,
		phase = "placement",
		heroes = {},
		occupied = {},
		usedHeroIds = {},
		placementSide = 1, -- lado 1 escolhe primeiro: 1,2,1,2...
		starterId = sides[1].id,
		turn = nil,
		turnToken = 0,
		winner = nil,
		finisher = nil,
		busy = false,
	}

	match.skillApi = BuildSkillApi(match)

	matches[matchId] = match
	matchBySlot[slot] = match

	-- O tabuleiro já existe no servidor; garante que ele existe no CLIENTE antes
	-- de mandar a câmera pra lá e antes do primeiro snapshot.
	StreamArenaTo(players, origin)

	-- a câmera do cliente se ancora na arena DESTA partida
	local hexSize = HexGrid.GetHexSize()
	BoardReady:FireClient(playerOne, hexSize, origin, 1)
	if playerTwo then
		BoardReady:FireClient(playerTwo, hexSize, origin, 2)
	end

	HeroView.PlayMatchSound(match.view, "MatchStart")

	Broadcast(match)
	print(("MatchManager: partida %d no slot %d (%s)."):format(matchId, slot, playerTwo and "PvP" or "vs bot"))
	return true
end

local function EndMatch(match)
	HeroView.ClearMatch(match.view)
	HeroView.DestroyView(match.view)

	if match.boardFolder and match.boardFolder.Parent then
		match.boardFolder:Destroy()
	end

	for _, side in ipairs(match.sides) do
		if side.player then
			MatchUpdate:FireClient(side.player, { phase = "lobby" })
		end
	end

	matches[match.id] = nil
	matchBySlot[match.slot] = nil
end

function MatchManager.Replay(player)
	local match = MatchOfPlayer(player)
	if not match or match.phase ~= "finished" then return end

	local playerOne = match.sides[1].player
	local playerTwo = match.sides[2].player
	local slot = match.slot

	-- se o dono do lado 1 saiu, quem sobrou reassume como lado 1
	if not playerOne then
		playerOne, playerTwo = playerTwo, nil
	end
	if not playerOne then return end

	-- derruba a partida antiga sem mandar ninguém pro lobby: a revanche entra
	-- no lugar dela, na mesma arena
	HeroView.ClearMatch(match.view)
	HeroView.DestroyView(match.view)
	matches[match.id] = nil
	matchBySlot[slot] = nil

	MatchManager.StartMatch(playerOne, playerTwo, slot)
end

-- Abandono: quem sai não leva XP; quem ficou recebe como vitória. Só vale pra
-- partida em andamento — depois do fim, "voltar pro lobby" é só sair da tela de
-- resultado, e o XP já foi pago pelo CheckGameOver.
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
	if side then AwardAbandon(match, side) end

	EndMatch(match)
end

-- Um jogador caiu no meio da partida: encerra pra todo mundo em vez de deixar
-- o outro preso esperando um turno que nunca vem.
function MatchManager.HandlePlayerLeft(player)
	local match = MatchOfPlayer(player)
	if not match then return end

	local side = SideOfPlayer(match, player)
	if not side then return end

	AwardAbandon(match, side)
	side.player = nil
	EndMatch(match)
end

function MatchManager.ActiveCount()
	local count = 0
	for _ in pairs(matches) do count += 1 end
	return count
end

return MatchManager
