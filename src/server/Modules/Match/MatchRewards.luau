local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local HeroData = require(ReplicatedStorage.Modules.HeroData)
local Campaign = require(ReplicatedStorage.Modules.Campaign)
local MatchQuery = require(script.Parent.MatchQuery)
local ProgressionService = require(ServerScriptService.Modules.Data.ProgressionService)
local HeroStatsService = require(ServerScriptService.Modules.Data.HeroStatsService)
local HeroUsageService = require(ServerScriptService.Modules.Data.HeroUsageService)
local HeroUnlockService = require(ServerScriptService.Modules.Data.HeroUnlockService)
local FightStore = require(ServerScriptService.Modules.Data.FightStore)
local Objectives = require(ServerScriptService.Modules.Modes.Objectives)

local SideOf = MatchQuery.SideOf
local OpponentSide = MatchQuery.OpponentSide

local MatchRewards = {}

function MatchRewards.AwardXp(match, side, result, survivors)
	if not match.rules.progression then return end
	if not side or side.isBot or not side.player then return end
	task.spawn(ProgressionService.AwardMatchXp, side.player, result, survivors, match.vsBot)
end

-- ===== ESTRELAS DO CONFRONTO =====
-- Avaliado NO INSTANTE da vitória, dentro do CheckGameOver: um passo depois o
-- EndMatch já limpou o tabuleiro, e contar herói de pé num tabuleiro vazio daria
-- zero sempre.
--
-- Só confronto de campanha com jogador humano e progressão ligada. Bot contra
-- bot, BalanceSim, desafio e sandbox passam pelo mesmo CheckGameOver e têm que
-- sair antes de encostar em DataStore.
function MatchRewards.AwardFightStars(match, winningSide)
	if not match.fight then return end
	if not match.rules.progression then return end
	if not winningSide.player or winningSide.isBot then return end
	if match.starsDone then return end
	match.starsDone = true

	local run = { playerId = winningSide.id, enemyId = OpponentSide(match, winningSide.id).id }
	local rules = Campaign.StarsFor(match.fight)

	-- Uma pela vitória, mais uma por linha cumprida. A soma reproduz a regra em
	-- degrau porque "sem promoção" está nas duas linhas (ver Campaign).
	local earned = 1
	for _, star in ipairs(rules) do
		if Objectives.Eval(match, run, star.check) == Objectives.DONE then
			earned += 1
		end
	end

	local gained = FightStore.Record(winningSide.player, match.fight.hero, earned)

	match.fightStars = {
		earned = earned,
		best = FightStore.StarsOf(winningSide.player, match.fight.hero),
		max = Campaign.MAX_STARS,
		gained = gained,
		xp = gained * Campaign.XP_PER_STAR,
		ownerId = winningSide.id,
	}

	-- Só estrela NOVA paga. Repetir o confronto com o mesmo resultado rende zero,
	-- e é isso que fecha a porta do farm sem precisar de trava de tempo.
	if gained > 0 then
		task.spawn(ProgressionService.AwardXp, winningSide.player, match.fightStars.xp)
	end
end

function MatchRewards.AwardFightHero(match, side)
	if not match.rules.progression then return end
	if not match.fight or not side or side.isBot or not side.player then return end
	task.spawn(HeroUnlockService.Unlock, side.player, match.fight.hero)
end

function MatchRewards.RecordHeroStats(match)
	if match.statsRecorded then return end
	if not (match.rules.progression or match.simulated) then return end
	match.statsRecorded = true

	local entries = {}

	local rootOf, familyAlive = {}, {}
	for _, hero in pairs(match.heroes) do
		local root = hero
		while root.summoner do root = root.summoner end
		rootOf[hero] = root
		if hero.isAlive then familyAlive[root] = true end
	end

	for _, hero in pairs(match.heroes) do
		local side = SideOf(match, hero.ownerId)
		if side then
			local result
			if match.winner == "draw" then
				result = "draws"
			elseif match.winner == side.id then
				result = "wins"
			else
				result = "losses"
			end

			local root = rootOf[hero]
			local row = entries[root.dataId] or {
				matches = 0, wins = 0, losses = 0, draws = 0,
				damageDealt = 0, damageTaken = 0, healed = 0,
				kills = 0, deaths = 0, survived = 0,
				attacks = 0, turnsAlive = 0, ccApplied = 0, special = {},
				pvpMatches = 0, pvpWins = 0,
			}

			if hero == root then
				row.matches += 1
				row[result] += 1

				if not match.vsBot then
					row.pvpMatches += 1
					if result == "wins" then row.pvpWins += 1 end
				end

				if familyAlive[root] then row.survived += 1 else row.deaths += 1 end
			end
			row.damageDealt += hero.stats.dealt
			row.damageTaken += hero.stats.taken
			row.healed += hero.stats.healed
			row.kills += hero.stats.kills
			row.attacks += hero.stats.attacks
			row.turnsAlive += hero.stats.turnsAlive
			row.ccApplied += hero.stats.ccApplied
			for key, value in pairs(hero.stats.special) do
				row.special[key] = (row.special[key] or 0) + value
			end

			entries[root.dataId] = row
		end
	end

	if match.simulated then
		if match.onStats then
			local rosters = { {}, {} }
			for _, hero in pairs(match.heroes) do
				local side = SideOf(match, hero.ownerId)
				if side and not hero.summoner and not HeroData.IsSummon(hero.dataId) then
					table.insert(rosters[side.index], hero.dataId)
				end
			end
			table.sort(rosters[1])
			table.sort(rosters[2])

			match.onStats(entries, {
				turns = match.turn and match.turn.number or 0,
				winner = match.winner,
				sideOneId = match.sides[1].id,
				sideTwoId = match.sides[2].id,
				theme = match.theme and match.theme.id or "?",
				timeout = match.winner == "draw",
				rosters = rosters,
			})
		end
	else
		HeroStatsService.AddMatch(entries)

		for _, side in ipairs(match.sides) do
			if side.player then
				local used = {}
				for _, hero in pairs(match.heroes) do
					if hero.ownerId == side.id and not hero.summoner
						and not HeroData.IsSummon(hero.dataId) then
						table.insert(used, hero.dataId)
					end
				end
				task.spawn(HeroUsageService.AddMatch, side.player.UserId, used)
			end
		end
	end
end
return MatchRewards
