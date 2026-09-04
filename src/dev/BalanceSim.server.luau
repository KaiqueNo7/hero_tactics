local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")

if not RunService:IsStudio() then
	return
end

if RunService:IsStudio() then
	return
end

local HeroData = require(ReplicatedStorage.Modules.HeroData)
local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local MatchManager = require(ServerScriptService.Modules.MatchManager)

local BALANCE_SIM_MATCHES = 1000
local BALANCE_SIM_SEED = nil
local CONCURRENT = 300
local PROGRESS_EVERY = 25
local HEROES_PER_SIDE = 3
local MIN_SYNERGY_GAMES = 5
local MIN_COMPOSITION_GAMES = 3
local MIN_MATCHUP_GAMES = 5
local TOP_ROWS = 12

local ACC_KEYS = {
	"matches", "wins", "damageDealt", "damageTaken", "healed",
	"kills", "deaths", "survived", "attacks", "turnsAlive", "ccApplied",
}

local DEVELOPMENT = { Zaro = true }

local SUM_ONLY = {
	escapeDistanceSum = true,
	escapeTilesBeforeRange = true,
	escapeTilesAfterRange = true,
	turnsBeforeFrenzySum = true,
	summonFirstAttackTurnSum = true,
	summonDistanceSum = true,
	summonsThatAttacked = true,
	shieldLifetimeTurnSum = true,
	shieldsEnded = true,
	weakPointHitGapSum = true,
	weakPointHitGaps = true,
	weakPointAttacks = true,
}

local DERIVED = {
	{ "escapeSuccessRate",            "successfulEscapes",        "escapeAttempts",       true },
	{ "avgFreeEscapeTiles",           "escapeTilesBeforeRange",   "escapeAttempts" },
	{ "avgValidEscapeTiles",          "escapeTilesAfterRange",    "escapeAttempts" },
	{ "avgEscapeDistance",            "escapeDistanceSum",        "successfulEscapes" },
	{ "avgTurnsBeforeFrenzy",         "turnsBeforeFrenzySum",     "frenzyActivations" },
	{ "avgFirstAttackTurnPerSummon",  "summonFirstAttackTurnSum", "summonsThatAttacked" },
	{ "avgSummonTravelDistance",      "summonDistanceSum",        "summonMoves" },
	{ "avgShieldLifetime",            "shieldLifetimeTurnSum",    "shieldsEnded" },
	{ "avgDamagePerShieldBlock",      "damageBlockedByShield",    "shieldBlocks" },
	{ "weakPointHitRate",             "weakPointsHit",            "weakPointAttacks",     true },
	{ "avgTurnsBetweenWeakPointHits", "weakPointHitGapSum",       "weakPointHitGaps" },
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

local synergyStats = {}      -- ["a|b"]   = { games, wins }
local compositionStats = {}  -- ["a|b|c"] = { games, wins }
local matchupStats = {}      -- ["a|b"]   = { games, wins }  (a enfrentando b)

local matchupCompositionStats = {} -- ["a|b|c vs d|e|f"] = { games, wins }

local function Bump(store, key, won)
	local row = store[key]
	if not row then
		row = { games = 0, wins = 0 }
		store[key] = row
	end
	row.games += 1
	if won then row.wins += 1 end
end

local function NameOf(dataId)
	local data = HeroData.GetById(dataId)
	return data and data.name or ("#" .. tostring(dataId))
end

local function KeyOf(ids, separator)
	local names = {}
	for _, dataId in ipairs(ids) do table.insert(names, NameOf(dataId)) end
	table.sort(names)
	return table.concat(names, separator)
end

local function RecordTeams(rosters, sideOneWon, sideTwoWon)
	if not rosters or not rosters[1] or not rosters[2] then return end

	local venceu = { sideOneWon, sideTwoWon }

	for index, team in ipairs(rosters) do
		local won = venceu[index]
		local outros = rosters[index == 1 and 2 or 1]

		for i = 1, #team do
			for j = i + 1, #team do
				Bump(synergyStats, KeyOf({ team[i], team[j] }, " + "), won)
			end

			for _, inimigo in ipairs(outros) do
				Bump(matchupStats, NameOf(team[i]) .. "|" .. NameOf(inimigo), won)
			end
		end

		Bump(compositionStats, KeyOf(team, " / "), won)
	end

	Bump(matchupCompositionStats,
		KeyOf(rosters[1], " / ") .. "  vs  " .. KeyOf(rosters[2], " / "), sideOneWon)
end

local started, finished = 0, 0
local sideOneWins, sideTwoWins, draws = 0, 0, 0
local turnSum, turnMin, turnMax = 0, math.huge, 0
local originalPlaceDelay = GameConfig.BOT_PLACE_DELAY
local originalMaxMatches = GameConfig.MAX_LIVE_MATCHES

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

	local umVenceu = summary.winner ~= "draw" and summary.winner == summary.sideOneId
	local doisVenceu = summary.winner ~= "draw" and summary.winner ~= summary.sideOneId

	if summary.winner == "draw" then
		draws += 1
	elseif umVenceu then
		sideOneWins += 1
		arena.sideOne += 1
	else
		sideTwoWins += 1
		arena.sideTwo += 1
	end

	RecordTeams(summary.rosters, umVenceu, doisVenceu)
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
			row.name .. (DEVELOPMENT[row.name] and " *" or ""),
			row.matches, row.winRate * 100, row.damage, row.taken, row.healed,
			row.kills, row.deaths, row.attacks, row.perAttack, row.turns, row.cc,
			row.survival * 100))
	end
	table.insert(lines, "* EM TESTE — dados coletados, mas fora de toda conclusao de meta abaixo.")

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
			local games = math.max(row.matches, 1)
			local block = {}

			local perMatch = {}
			for key, value in pairs(row.special) do
				if not SUM_ONLY[key] then
					table.insert(perMatch, ("      %-30s %8.2f"):format(key .. "/J", value / games))
				end
			end
			table.sort(perMatch)

			local averages = {}
			for _, spec in ipairs(DERIVED) do
				local name, over, under, isRate = spec[1], spec[2], spec[3], spec[4]
				local base = row.special[under]
				if base and base > 0 and row.special[over] then
					local value = row.special[over] / base
					table.insert(averages, ("      %-30s %8s"):format(name,
						isRate and ("%.1f%%"):format(value * 100) or ("%.2f"):format(value)))
				end
			end

			table.insert(block, ("  %s%s"):format(row.name,
				DEVELOPMENT[row.name] and "   [EM TESTE — fora da leitura de meta]" or ""))
			for _, line in ipairs(perMatch) do table.insert(block, line) end
			for _, line in ipairs(averages) do table.insert(block, line) end

			table.insert(specials, table.concat(block, "\n"))
		end
	end
	if #specials > 0 then
		table.insert(lines, "")
		table.insert(lines, "HABILIDADES   (/J = por partida do heroi; avg/rate = media real, nao soma)")
		for _, line in ipairs(specials) do
			table.insert(lines, line)
		end
	end

	local soloRate = {}
	for _, row in ipairs(rows) do soloRate[row.name] = row.winRate end

	local function Ranked(store, minimum, extra)
		local out = {}
		for key, row in pairs(store) do
			if row.games >= minimum then
				local rate = row.wins / row.games
				table.insert(out, {
					key = key, games = row.games, rate = rate,
					extra = extra and extra(key, rate) or nil,
				})
			end
		end
		table.sort(out, function(a, b)
			if a.rate ~= b.rate then return a.rate > b.rate end
			return a.games > b.games
		end)
		return out
	end

	local function SynergyDelta(key, rate)
		local a, b = key:match("^(.-) %+ (.+)$")
		local rateA, rateB = soloRate[a], soloRate[b]
		if not (rateA and rateB) then return nil end
		return (rate - (rateA + rateB) / 2) * 100
	end

	local duplas = Ranked(synergyStats, MIN_SYNERGY_GAMES, SynergyDelta)
	local comps = Ranked(compositionStats, MIN_COMPOSITION_GAMES)
	local matchups = Ranked(matchupStats, MIN_MATCHUP_GAMES)

	if #duplas > 0 then
		table.insert(lines, "")
		table.insert(lines, ("SINERGIAS — DUPLAS (minimo %d jogos)"):format(MIN_SYNERGY_GAMES))
		table.insert(lines, ("%-28s %6s %7s %8s"):format("DUPLA", "JOGOS", "WIN%", "DELTA"))
		for index, row in ipairs(duplas) do
			if index > TOP_ROWS then break end
			table.insert(lines, ("%-28s %6d %6.1f%% %+8.1f"):format(
				row.key, row.games, row.rate * 100, row.extra or 0))
		end
	end

	if #comps > 0 then
		table.insert(lines, "")
		table.insert(lines, ("COMPOSICOES (minimo %d jogos)"):format(MIN_COMPOSITION_GAMES))
		table.insert(lines, ("%-38s %6s %7s"):format("COMPOSICAO", "JOGOS", "WIN%"))
		for index, row in ipairs(comps) do
			if index > TOP_ROWS then break end
			table.insert(lines, ("%-38s %6d %6.1f%%"):format(row.key, row.games, row.rate * 100))
		end
	end

	if #matchups > 0 then
		table.insert(lines, "")
		table.insert(lines, ("MATCHUPS (minimo %d jogos)"):format(MIN_MATCHUP_GAMES))
		table.insert(lines, ("%-14s %-14s %6s %7s"):format("HEROI", "CONTRA", "JOGOS", "WIN%"))

		local mostra = {}
		for index = 1, math.min(TOP_ROWS // 2, #matchups) do
			table.insert(mostra, matchups[index])
		end
		for index = math.max(#matchups - (TOP_ROWS // 2) + 1, #mostra + 1), #matchups do
			table.insert(mostra, matchups[index])
		end

		for _, row in ipairs(mostra) do
			local heroi, contra = row.key:match("^(.-)|(.+)$")
			table.insert(lines, ("%-14s %-14s %6d %6.1f%%"):format(
				heroi, contra, row.games, row.rate * 100))
		end
	end

	local meta = {}
	for _, row in ipairs(rows) do
		if not DEVELOPMENT[row.name] then table.insert(meta, row) end
	end

	local function InDevelopment(key)
		for name in pairs(DEVELOPMENT) do
			if key:find(name, 1, true) then return true end
		end
		return false
	end

	local function MetaOnly(lista)
		local out = {}
		for _, row in ipairs(lista) do
			if not InDevelopment(row.key) then table.insert(out, row) end
		end
		return out
	end

	if #meta > 0 then
		local best = {
			damage = meta[1], healed = meta[1], kills = meta[1], survival = meta[1],
		}
		for _, row in ipairs(meta) do
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
			meta[1].name, meta[1].winRate * 100,
			meta[#meta].name, meta[#meta].winRate * 100))
		table.insert(lines, ("  Maior dano/J: %s (%.1f)   Maior cura/J: %s (%.1f)"):format(
			best.damage.name, best.damage.damage, best.healed.name, best.healed.healed))
		table.insert(lines, ("  Maior kills/J: %s (%.2f)   Maior sobrev.: %s (%.1f%%)"):format(
			best.kills.name, best.kills.kills, best.survival.name, best.survival.survival * 100))

		local function Extremos(rotuloAlto, rotuloBaixo, lista, formata)
			if #lista == 0 then return end
			table.insert(lines, ("  %s: %s (%.1f%%, %d jogos)"):format(
				rotuloAlto, formata(lista[1].key), lista[1].rate * 100, lista[1].games))
			if #lista > 1 then
				local ultimo = lista[#lista]
				table.insert(lines, ("  %s: %s (%.1f%%, %d jogos)"):format(
					rotuloBaixo, formata(ultimo.key), ultimo.rate * 100, ultimo.games))
			end
		end

		local function ComoEsta(key) return key end
		local function ComoMatchup(key) return (key:gsub("|", " vs ")) end

		Extremos("Melhor sinergia", "Pior sinergia", MetaOnly(duplas), ComoEsta)
		Extremos("Melhor composicao", "Pior composicao", MetaOnly(comps), ComoEsta)
		Extremos("Matchup mais favoravel", "Matchup mais desfavoravel", MetaOnly(matchups), ComoMatchup)

		local maiorDelta = nil
		for _, row in ipairs(MetaOnly(duplas)) do
			if row.extra and (not maiorDelta or row.extra > maiorDelta.extra) then
				maiorDelta = row
			end
		end
		if maiorDelta then
			table.insert(lines, ("  Maior sinergia acima do esperado: %s (%+.1f, %.1f%%, %d jogos)")
				:format(maiorDelta.key, maiorDelta.extra, maiorDelta.rate * 100, maiorDelta.games))
		end

		local confrontos, comAmostra = 0, 0
		for _, row in pairs(matchupCompositionStats) do
			confrontos += 1
			if row.games >= MIN_COMPOSITION_GAMES then comAmostra += 1 end
		end
		table.insert(lines, ("  Confrontos de composicao registrados: %d (%d com %d+ jogos)")
			:format(confrontos, comAmostra, MIN_COMPOSITION_GAMES))
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
		GameConfig.MAX_LIVE_MATCHES = originalMaxMatches
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
GameConfig.MAX_LIVE_MATCHES = math.max(originalMaxMatches, CONCURRENT)
print(("BalanceSim: %d partidas, %d por vez (%d slots de arena). Seed: %d"):format(
	BALANCE_SIM_MATCHES, CONCURRENT, GameConfig.MAX_LIVE_MATCHES, seed))

for _ = 1, CONCURRENT do
	StartOne()
end
