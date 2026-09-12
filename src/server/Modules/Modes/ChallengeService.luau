local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Arenas = require(ReplicatedStorage.Modules.Arenas)
local HeroChallenges = require(ReplicatedStorage.Modules.HeroChallenges)
local HeroData = require(ReplicatedStorage.Modules.HeroData)
local HexGrid = require(ReplicatedStorage.Modules.HexGrid)
local ChallengeStore = require(ServerScriptService.Modules.ChallengeStore)
local HeroUnlockService = require(ServerScriptService.Modules.HeroUnlockService)
local HeroView = require(ServerScriptService.Modules.HeroView)
local MatchManager = require(ServerScriptService.Modules.MatchManager)
local Objectives = require(ServerScriptService.Modules.Objectives)
local ProgressionService = require(ServerScriptService.Modules.ProgressionService)

local Internal = MatchManager.Internal
local GameAction = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("GameAction")

local ChallengeService = {}

local STATUS_TURNS = {
	poison = 3,
	freeze = 2,
	paralysis = 1,
	wound = 2,
	charge = 2,
}

local function MatchOf(player)
	local match = Internal.MatchOfPlayer(player)
	if match and match.challenge then return match end
	return nil
end

function ChallengeService.Unlocked(player, heroId, index)
	local spec = HeroChallenges.Get(heroId, index)
	if not spec then return false end

	local owns = HeroUnlockService.OwnsHero(player, heroId)
	local stars = ChallengeStore.StarsOf(player, heroId)
	return HeroChallenges.StateOf(stars, owns, index) ~= "locked"
end

local function ApplyUnit(match, unit, ownerId)
	local hero = Internal.CreateHero(match, unit.hero, ownerId, unit.hex)
	if not hero then return nil end

	if unit.hp then
		hero.currentHp = math.clamp(math.floor(unit.hp), 1, hero.maxHp)
	end
	if unit.attack then
		hero.attack = math.max(0, math.floor(unit.attack))
	end
	if unit.weakPoint then
		hero.weakPoint = unit.weakPoint
	end

	for _, effect in ipairs(unit.status or {}) do
		Internal.ApplyStatusEffect(match, hero, {
			type = effect.type,
			duration = effect.turns or STATUS_TURNS[effect.type] or 2,
			stacks = effect.stacks,
		})
	end

	if unit.stealth then hero.stealth = true end

	HeroView.UpdateStats(hero)
	return hero
end

local function BuildScene(match)
	local spec = match.challenge.spec

	Internal.ClearScene(match)

	local run = {
		spec = spec,
		playerId = match.sides[1].id,
		enemyId = match.sides[2].id,
		playerByData = {},
		enemyByData = {},
		baseline = {},
		starState = {},
		resolved = false,
	}

	for _, unit in ipairs(spec.player) do
		local hero = ApplyUnit(match, unit, run.playerId)
		if hero then run.playerByData[unit.hero] = hero end
	end

	for _, unit in ipairs(spec.enemy) do
		local hero = ApplyUnit(match, unit, run.enemyId)
		if hero then run.enemyByData[unit.hero] = hero end
	end

	for _, hexId in ipairs(spec.objects or {}) do
		if HexGrid.Exists(hexId) and not match.occupied[hexId] then
			Internal.CreateBarrel(match, hexId)
		end
	end

	local tracked = Objectives.TrackedKeys(spec)
	for _, hero in pairs(match.heroes) do
		local line = { taken = hero.stats.taken }
		for key in pairs(tracked) do
			line[key] = line[key] or (hero.stats.special[key] or 0)
		end
		run.baseline[hero.uid] = line
	end

	for index in ipairs(spec.stars) do
		run.starState[index] = Objectives.PENDING
	end

	match.challenge.run = run
	match.starterId = run.playerId
	return run
end

local function StarsEarned(run)
	local earned = 1
	for _, state in ipairs(run.starState) do
		if state == Objectives.DONE then earned += 1 end
	end
	return earned
end

local function PublishState(match)
	local run = match.challenge.run
	local spec = run.spec
	local player = match.sides[1].player

	local stars = {}
	for index, star in ipairs(spec.stars) do
		table.insert(stars, { text = star.text, state = run.starState[index] })
	end

	local best = ChallengeStore.StarsOf(player, match.challenge.heroId)[match.challenge.index] or 0
	local bestTurns = ChallengeStore.TurnsOf(player, match.challenge.heroId)[match.challenge.index] or 0

	match.challengeState = {
		heroId = match.challenge.heroId,
		index = match.challenge.index,
		name = spec.name,
		concept = spec.concept,
		how = spec.how,
		objective = Objectives.Describe(spec.win),
		turn = match.turn and match.turn.number or 0,
		maxTurns = spec.maxTurns,
		stars = stars,
		outcome = run.outcome,
		reason = run.reason,
		earned = run.earnedStars,
		best = best,
		bestTurns = bestTurns,
		xp = run.xp,
		hasNext = HeroChallenges.Get(match.challenge.heroId, match.challenge.index + 1) ~= nil,
	}
end

local function Finish(match, outcome, reason)
	local run = match.challenge.run
	if run.resolved then return true end
	run.resolved = true

	run.outcome = outcome
	run.reason = reason
	run.earnedStars = outcome == "win" and StarsEarned(run) or 0

	match.phase = "finished"

	local player = match.sides[1].player
	if outcome == "win" and player then
		local turns = match.turn and match.turn.number or 0
		local gained = ChallengeStore.Record(player, match.challenge.heroId,
			match.challenge.index, run.earnedStars, turns)

		run.xp = gained * HeroChallenges.XP_PER_STAR
		if run.xp > 0 then
			task.spawn(ProgressionService.AwardXp, player, run.xp)
		end
	end

	PublishState(match)
	Internal.Broadcast(match)
	return true
end

local function Resolve(match)
	local challenge = match.challenge
	local run = challenge and challenge.run
	if not run then return false end
	if run.resolved then return true end

	local spec = run.spec

	for index, star in ipairs(spec.stars) do
		if run.starState[index] ~= Objectives.FAILED then
			run.starState[index] = Objectives.Eval(match, run, star.check)
		end
	end

	if Objectives.Eval(match, run, spec.win) == Objectives.DONE then
		return Finish(match, "win")
	end

	if spec.lose and Objectives.Eval(match, run, spec.lose) == Objectives.DONE then
		return Finish(match, "loss", "Seu herói caiu.")
	end

	local turn = match.turn and match.turn.number or 0
	if spec.maxTurns and turn > spec.maxTurns then
		return Finish(match, "loss", ("O limite de %d turnos acabou."):format(spec.maxTurns))
	end

	PublishState(match)
	return false
end

MatchManager.Resolvers.challenge = Resolve

function ChallengeService.Start(player, heroId, index, force)
	if not player then return false, "sem jogador" end

	heroId = tonumber(heroId)
	index = tonumber(index)
	if not (heroId and index) then return false, "pedido inválido" end

	local spec = HeroChallenges.Get(heroId, index)
	if not spec then return false, "desafio inexistente" end
	if not force and not ChallengeService.Unlocked(player, heroId, index) then
		return false, "desafio bloqueado"
	end
	if MatchManager.IsInMatch(player) then return false, "já está numa partida" end

	local theme = Arenas.ById(spec.arena) or Arenas.Random()

	local started = MatchManager.StartMatch(player, nil, nil, nil, {
		theme = theme,
		challenge = { heroId = heroId, index = index, spec = spec },
		rules = {
			draft = false,
			objects = false,
			promotion = false,
			suddenDeath = false,
			progression = false,
			resolve = "challenge",
			botPolicy = spec.botPolicy or "hold",
		},
	})

	if not started then return false, "sem arena livre" end

	local match = MatchOf(player)
	if not match then return false, "partida não subiu" end

	BuildScene(match)
	PublishState(match)
	Internal.BeginTurn(match, match.sides[1].id, 1)
	return true
end

function ChallengeService.Restart(player)
	local match = MatchOf(player)
	if not match then return false end

	local waited = 0
	while match.busy and waited < 3 do
		task.wait(0.05)
		waited += 0.05
	end
	if not MatchOf(player) then return false end

	BuildScene(match)
	PublishState(match)
	Internal.BeginTurn(match, match.sides[1].id, 1)
	return true
end

function ChallengeService.Exit(player)
	local match = MatchOf(player)
	if not match then return false end

	Internal.EndMatch(match)
	return true
end

function ChallengeService.Next(player)
	local match = MatchOf(player)
	if not match then return false end

	local heroId = match.challenge.heroId
	local index = match.challenge.index + 1
	if not HeroChallenges.Get(heroId, index) then return false end

	Internal.EndMatch(match)
	return ChallengeService.Start(player, heroId, index)
end

function ChallengeService.Handle(player, command, arg1, arg2)
	if command == "start" then
		local ok, why = ChallengeService.Start(player, arg1, arg2)
		if not ok then GameAction:FireClient(player, "challengeRefused", why) end
	elseif command == "restart" then
		ChallengeService.Restart(player)
	elseif command == "next" then
		ChallengeService.Next(player)
	elseif command == "exit" then
		ChallengeService.Exit(player)
	elseif command == "sync" then
		ChallengeStore.Push(player)
	end
end

function ChallengeService.Validate()
	local problems = {}

	if #HexGrid.GetAllHexes() == 0 then HexGrid.Generate() end

	local function fail(spec, text)
		table.insert(problems, ("%s: %s"):format(spec and spec.id or "?", text))
	end

	for _, heroId in ipairs(HeroChallenges.HeroIds()) do
		local hero = HeroData.GetById(heroId)
		if not hero then
			table.insert(problems, ("herói %s não existe no catálogo"):format(tostring(heroId)))
		end

		for index, spec in ipairs(HeroChallenges.ListFor(heroId)) do
			local used = {}
			local units = {}

			for _, unit in ipairs(spec.player) do table.insert(units, { unit, "player" }) end
			for _, unit in ipairs(spec.enemy) do table.insert(units, { unit, "enemy" }) end

			if #spec.player == 0 then fail(spec, "sem unidade do jogador") end
			if #spec.enemy == 0 then fail(spec, "sem inimigo") end

			for _, entry in ipairs(units) do
				local unit = entry[1]
				if not HeroData.GetById(unit.hero) then
					fail(spec, ("herói %s não existe"):format(tostring(unit.hero)))
				end
				if not HexGrid.Exists(unit.hex) then
					fail(spec, ("casa %s não existe"):format(tostring(unit.hex)))
				elseif used[unit.hex] then
					fail(spec, ("casa %s ocupada duas vezes"):format(unit.hex))
				end
				used[unit.hex] = true

				local data = HeroData.GetById(unit.hero)
				if data and unit.hp and unit.hp > data.hp then
					fail(spec, ("%s começa com mais vida que o máximo"):format(data.name))
				end
				if data and table.find(data.abilities or {}, "goodLuck") then
					fail(spec, ("%s tem sorte aleatória e quebra o determinismo"):format(data.name))
				end
			end

			for _, hexId in ipairs(spec.objects or {}) do
				if not HexGrid.Exists(hexId) then
					fail(spec, ("objeto na casa inexistente %s"):format(tostring(hexId)))
				elseif used[hexId] then
					fail(spec, ("objeto na casa %s já ocupada"):format(hexId))
				end
				used[hexId] = true
			end

			if not Arenas.ById(spec.arena) then
				fail(spec, ("arena %s não existe"):format(tostring(spec.arena)))
			end
			if not spec.win or not Objectives.Has(spec.win.kind) then
				fail(spec, "sem condição de vitória válida")
			end
			if not spec.maxTurns or spec.maxTurns < 1 then
				fail(spec, "maxTurns inválido")
			end
			if #spec.stars ~= HeroChallenges.STARS_PER_CHALLENGE - 1 then
				fail(spec, ("precisa de %d condições de estrela"):format(HeroChallenges.STARS_PER_CHALLENGE - 1))
			end

			local roster = {}
			for _, entry in ipairs(units) do roster[entry[1].hero] = entry[2] end

			local function checkRef(check, label)
				if type(check) ~= "table" then return end
				if not Objectives.Has(check.kind) then
					fail(spec, ("%s usa objetivo desconhecido %s"):format(label, tostring(check.kind)))
					return
				end
				if check.hero and not roster[check.hero] then
					fail(spec, ("%s cita herói fora do elenco"):format(label))
				end
				if check.hex and not HexGrid.Exists(check.hex) then
					fail(spec, ("%s cita casa inexistente"):format(label))
				end
				if check.turns and spec.maxTurns and check.turns > spec.maxTurns then
					fail(spec, ("%s pede mais turnos que o limite"):format(label))
				end
			end

			checkRef(spec.win, "vitória")
			checkRef(spec.lose, "derrota")
			for starIndex, star in ipairs(spec.stars) do
				if type(star.text) ~= "string" or star.text == "" then
					fail(spec, ("estrela %d sem texto"):format(starIndex))
				end
				checkRef(star.check, ("estrela %d"):format(starIndex))
			end

			if HeroChallenges.Get(heroId, index) ~= spec then
				fail(spec, "índice fora de ordem")
			end
		end
	end

	return problems
end

return ChallengeService
