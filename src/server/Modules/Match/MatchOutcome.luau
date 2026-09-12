local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local MatchQuery = require(ServerScriptService.Modules.Match.MatchQuery)
local MatchBroadcast = require(ServerScriptService.Modules.Match.MatchBroadcast)
local MatchRewards = require(ServerScriptService.Modules.Match.MatchRewards)
local CombatCore = require(ServerScriptService.Modules.Combat.CombatCore)
local LeaderboardService = require(ServerScriptService.Modules.Data.LeaderboardService)

local MatchOutcome = {}

-- Quem decide o fim fora da eliminação: o `rules.resolve` nomeia um destes.
MatchOutcome.Resolvers = {}

local LivingHeroesOf = MatchQuery.LivingHeroesOf
local Broadcast = MatchBroadcast.Send
local DAMAGE_SOURCES = CombatCore.DAMAGE_SOURCES
local AwardXp = MatchRewards.AwardXp
local AwardFightStars = MatchRewards.AwardFightStars
local AwardFightHero = MatchRewards.AwardFightHero
local RecordHeroStats = MatchRewards.RecordHeroStats

local EndMatch

function MatchOutcome.Bind(deps)
	EndMatch = deps.EndMatch
end

function MatchOutcome.IsRankedPvp(match)
	if match.simulated then return nil, "BalanceSim" end
	if not match.rules.progression then return nil, "modo sem progressao" end
	if match.fight then return nil, "campanha" end
	if not match.turn then return nil, "partida nao chegou a comecar" end

	for _, side in ipairs(match.sides) do
		if side.isBot then return nil, "envolve bot" end
		if not (side.player or side.awaitingReconnect) then
			return nil, "lado sem jogador"
		end
	end

	return true
end

function MatchOutcome.CheckGameOver(match)
	if match.rules.resolve == "manual" then return false end

	if match.rules.resolve ~= "elimination" then
		local resolver = MatchOutcome.Resolvers[match.rules.resolve]
		return resolver ~= nil and resolver(match) == true
	end

	local aliveOne = #LivingHeroesOf(match, match.sides[1].id)
	local aliveTwo = #LivingHeroesOf(match, match.sides[2].id)

	if aliveOne > 0 and aliveTwo > 0 then return false end

	if not match.finisher and match.lastDeath and (os.clock() - match.lastDeath.at) < 5 then
		local killer = match.lastDeath.killer
		local cause = match.lastDeath.sourceKey and DAMAGE_SOURCES[match.lastDeath.sourceKey]
		match.finisher = {
			dataId = killer and killer.dataId or match.lastDeath.dataId,
			name = killer and killer.name or cause or match.lastDeath.name,
			victim = match.lastDeath.name,
			ownerId = killer and killer.ownerId or match.lastDeath.ownerId,
			sideIndex = killer and killer.sideIndex or match.lastDeath.sideIndex,
			hex = killer and killer.hex or match.lastDeath.hex,
		}
	end

	if match.finisher then
		match.finisher.final = true
		Broadcast(match)
		match.busy = true
		task.wait(GameConfig.FINAL_KILL_HOLD)
		match.busy = false
	end

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

		if not match.rankingDone then
			match.rankingDone = true

			local ranked, why = MatchOutcome.IsRankedPvp(match)
			if ranked and winningSide.player then
				print(("[Ranking] PvP valido — vitoria registrada para %s"):format(winningSide.player.Name))
				LeaderboardService.RecordWin(tonumber(winningSide.id))
			else
				print(("[Ranking] resultado ignorado — %s"):format(why))
			end
		end

		-- ANTES do AwardXp e do EndMatch: as estrelas leem heróis de pé e o
		-- número do turno, e os dois só existem enquanto a partida existe.
		AwardFightStars(match, winningSide)

		AwardXp(match, winningSide, "win", survivors)
		AwardXp(match, losingSide, "loss")

		AwardFightHero(match, winningSide)
	end

	RecordHeroStats(match)

	local winner = match.winner
	local noHumans = not (match.sides[1].player or match.sides[2].player)
	if noHumans or match.onFinish then
		task.defer(function()
			if noHumans then EndMatch(match) end
			if match.onFinish then match.onFinish(winner) end
		end)
	end

	return true
end

return MatchOutcome
