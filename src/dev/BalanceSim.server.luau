local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")

if not RunService:IsStudio() then
	return
end

local HeroData = require(ReplicatedStorage.Modules.HeroData)
local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local MatchManager = require(ServerScriptService.Modules.MatchManager)

local BALANCE_SIM_MATCHES = 300
local BALANCE_SIM_SEED = nil
local CONCURRENT = 4
local PROGRESS_EVERY = 25
local HEROES_PER_SIDE = 3

local ACC_KEYS = {
	"matches", "wins", "damageDealt", "damageTaken", "healed",
	"kills", "deaths", "survived", "attacks", "turnsAlive", "ccApplied",
}

local seed = BALANCE_SIM_SEED or (os.time() % 2147483647)
local rng = Random.new(seed)

local roster = {}
for _, data in ipairs(HeroData.CATALOG) do
	if not HeroData.IsSummon(data.id) then
		table.insert(roster, data.id)
	end
end

local picks = {}
for _, dataId in ipairs(roster) do
	picks[dataId] = 0
end

local totals = {}
local arenas = {}
local started, finished = 0, 0
local sideOneWins, sideTwoWins, draws = 0, 0, 0
local turnSum, turnMin, turnMax = 0, math.huge, 0
local originalPlaceDelay = GameConfig.BOT_PLACE_DELAY

local function Shuffle(list)
	for index = #list, 2, -1 do
		local other = rng:NextInteger(1, index)
		list[index], list[other] = list[other], list[index]
	end
	return list
end

local function DrawRosters()
	local pool = table.clone(roster)
	Shuffle(pool)
	table.sort(pool, function(a, b) return picks[a] < picks[b] end)

	local chosen = {}
	for index = 1, HEROES_PER_SIDE * 2 do
		local dataId = pool[index]
		table.insert(chosen, dataId)
		picks[dataId] += 1
	end

	Shuffle(chosen)
	return {
		{ chosen[1], chosen[2], chosen[3] },
		{ chosen[4], chosen[5], chosen[6] },
	}
end

local function Accumulate(entries, summary)
	for dataId, row in pairs(entries) do
		local acc = totals[dataId]
		if not acc then
			acc = { special = {} }
			for _, key in ipairs(ACC_KEYS) do acc[key] = 0 end
			totals[dataId] = acc
		end

		for _, key in ipairs(ACC_KEYS) do
			acc[key] += row[key] or 0
		end
		for key, value in pairs(row.special or {}) do
			acc.special[key] = (acc.special[key] or 0) + value
		end
	end

	if not summary then return end

	local arena = arenas[summary.theme]
	if not arena then
		arena = { matches = 0, sideOne = 0, sideTwo = 0, turns = 0 }
		arenas[summary.theme] = arena
	end
	arena.matches += 1
	arena.turns += summary.turns

	turnSum += summary.turns
	turnMin = math.min(turnMin, summary.turns)
	turnMax = math.max(turnMax, summary.turns)

	if summary.winner == "draw" then
		draws += 1
	elseif summary.winner == summary.sideOneId then
		sideOneWins += 1
		arena.sideOne += 1
	else
		sideTwoWins += 1
		arena.sideTwo += 1
	end
end

local function Validate(rows)
	local problems = {}
	local totalGames, totalWins = 0, 0
	local least, most = math.huge, 0

	for _, row in ipairs(rows) do
		totalGames += row.matches
		totalWins += row.wins
		least = math.min(least, row.matches)
		most = math.max(most, row.matches)

		for key, value in pairs(row) do
			if type(value) == "number" and (value ~= value or value == math.huge) then
				table.insert(problems, ("%s: %s invalido"):format(row.name, key))
			end
		end
	end

	local expected = finished * HEROES_PER_SIDE * 2
	if totalGames ~= expected then
		table.insert(problems, ("soma de JOGOS %d != %d esperados"):format(totalGames, expected))
	end

	for dataId in pairs(totals) do
		if HeroData.IsSummon(dataId) then
			table.insert(problems, ("invocacao %d virou linha de heroi"):format(dataId))
		end
	end

	if sideOneWins + sideTwoWins + draws ~= finished then
		table.insert(problems, ("A+B+empates %d != %d partidas"):format(
			sideOneWins + sideTwoWins + draws, finished))
	end

	if totalWins ~= (sideOneWins + sideTwoWins) * HEROES_PER_SIDE then
		table.insert(problems, ("soma de vitorias %d nao fecha com %d partidas decididas"):format(
			totalWins, sideOneWins + sideTwoWins))
	end

	if most - least > math.max(4, most * 0.25) then
		table.insert(problems, ("distribuicao desigual: de %d a %d jogos"):format(least, most))
	end

	return problems
end

local function Report()
	local rows = {}
	for dataId, acc in pairs(totals) do
		local data = HeroData.GetById(dataId)
		if HeroData.IsSummon(dataId) then
			warn(("BalanceSim: invocacao %d entrou no relatorio — agregacao furada."):format(dataId))
			continue
		end
		if not data then
			warn(("BalanceSim: dataId %d nao existe no HeroData."):format(dataId))
			continue
		end

		local games = math.max(acc.matches, 1)
		table.insert(rows, {
			name = data.name,
			matches = acc.matches,
			wins = acc.wins,
			winRate = acc.wins / games,
			damage = acc.damageDealt / games,
			taken = acc.damageTaken / games,
			healed = acc.healed / games,
			kills = acc.kills / games,
			deaths = acc.deaths / games,
			attacks = acc.attacks / games,
			perAttack = acc.attacks > 0 and acc.damageDealt / acc.attacks or 0,
			turns = acc.turnsAlive / games,
			cc = acc.ccApplied / games,
			survival = acc.survived / games,
			special = acc.special,
		})
	end

	table.sort(rows, function(a, b) return a.winRate > b.winRate end)

	local lines = {
		("SIMULACAO — %d partidas bot vs bot"):format(finished),
		("Seed: %d"):format(seed),
		"",
		("%-12s %5s %6s %7s %8s %6s %6s %7s %6s %7s %8s %5s %7s"):format(
			"HEROI", "JOGOS", "WIN%", "DANO/J", "DMGREC/J", "CURA/J",
			"KILL/J", "MORTE/J", "ATQ/J", "DMG/ATQ", "TURNOS/J", "CC/J", "SOBREV."),
	}

	for _, row in ipairs(rows) do
		table.insert(lines, ("%-12s %5d %5.1f%% %7.1f %8.1f %6.1f %6.2f %7.2f %6.1f %7.2f %8.1f %5.2f %6.1f%%"):format(
			row.name, row.matches, row.winRate * 100, row.damage, row.taken, row.healed,
			row.kills, row.deaths, row.attacks, row.perAttack, row.turns, row.cc,
			row.survival * 100))
	end

	table.insert(lines, "")
	table.insert(lines, "ARENAS")
	table.insert(lines, ("%-12s %8s %8s %8s %10s"):format(
		"ARENA", "PARTIDAS", "LADO A", "LADO B", "TURNOS/P"))
	for theme, arena in pairs(arenas) do
		local m = math.max(arena.matches, 1)
		table.insert(lines, ("%-12s %8d %7.1f%% %7.1f%% %10.1f"):format(
			theme, arena.matches, arena.sideOne / m * 100, arena.sideTwo / m * 100, arena.turns / m))
	end

	local specials = {}
	for _, row in ipairs(rows) do
		if next(row.special) then
			local parts = {}
			for key, value in pairs(row.special) do
				table.insert(parts, ("%s/J: %.2f"):format(key, value / math.max(row.matches, 1)))
			end
			table.sort(parts)
			table.insert(specials, ("  %s — %s"):format(row.name, table.concat(parts, "   ")))
		end
	end
	if #specials > 0 then
		table.insert(lines, "")
		table.insert(lines, "HABILIDADES")
		for _, line in ipairs(specials) do
			table.insert(lines, line)
		end
	end

	if #rows > 0 then
		local best = {
			damage = rows[1], healed = rows[1], kills = rows[1], survival = rows[1],
		}
		for _, row in ipairs(rows) do
			if row.damage > best.damage.damage then best.damage = row end
			if row.healed > best.healed.healed then best.healed = row end
			if row.kills > best.kills.kills then best.kills = row end
			if row.survival > best.survival.survival then best.survival = row end
		end

		table.insert(lines, "")
		table.insert(lines, "RESUMO")
		table.insert(lines, ("  Partidas: %d"):format(finished))
		table.insert(lines, ("  Participacoes de herois: %d"):format(finished * HEROES_PER_SIDE * 2))
		table.insert(lines, ("  Turnos: media %.1f, menor %d, maior %d"):format(
			turnSum / math.max(finished, 1), turnMin == math.huge and 0 or turnMin, turnMax))
		table.insert(lines, ("  Lado A: %.1f%%   Lado B: %.1f%%   Empates: %d"):format(
			sideOneWins / math.max(finished, 1) * 100,
			sideTwoWins / math.max(finished, 1) * 100, draws))
		table.insert(lines, ("  Maior win rate: %s (%.1f%%)   Menor: %s (%.1f%%)"):format(
			rows[1].name, rows[1].winRate * 100,
			rows[#rows].name, rows[#rows].winRate * 100))
		table.insert(lines, ("  Maior dano/J: %s (%.1f)   Maior cura/J: %s (%.1f)"):format(
			best.damage.name, best.damage.damage, best.healed.name, best.healed.healed))
		table.insert(lines, ("  Maior kills/J: %s (%.2f)   Maior sobrev.: %s (%.1f%%)"):format(
			best.kills.name, best.kills.kills, best.survival.name, best.survival.survival * 100))
	end

	local problems = Validate(rows)
	if #problems > 0 then
		table.insert(lines, "")
		table.insert(lines, "BALANCESIM VALIDATION FAILED")
		for _, problem in ipairs(problems) do
			table.insert(lines, "  - " .. problem)
		end
	end

	return table.concat(lines, "\n")
end

local StartOne

local function OnFinished()
	finished += 1

	if finished % PROGRESS_EVERY == 0 then
		print(("BalanceSim: %d/%d partidas"):format(finished, BALANCE_SIM_MATCHES))
	end

	if finished >= BALANCE_SIM_MATCHES then
		GameConfig.BOT_PLACE_DELAY = originalPlaceDelay
		print(Report())
	else
		StartOne()
	end
end

function StartOne()
	if started >= BALANCE_SIM_MATCHES then return end
	started += 1

	local ok = MatchManager.StartMatch(nil, nil, nil, nil, {
		botVsBot = true,
		rosters = DrawRosters(),
		onStats = Accumulate,
		onFinish = OnFinished,
	})

	if not ok then
		started -= 1
		task.delay(2, StartOne)
	end
end

GameConfig.BOT_PLACE_DELAY = 0
print(("BalanceSim: %d partidas, %d por vez. Seed: %d"):format(
	BALANCE_SIM_MATCHES, CONCURRENT, seed))

for _ = 1, CONCURRENT do
	StartOne()
end
