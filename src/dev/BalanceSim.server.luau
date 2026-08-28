local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")

if not RunService:IsStudio() then
	return
end

local HeroData = require(ReplicatedStorage.Modules.HeroData)
local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local MatchManager = require(ServerScriptService.Modules.MatchManager)

local TOTAL_MATCHES = 40
local CONCURRENT = 4

local totals = {}
local started, finished = 0, 0
local originalPlaceDelay = GameConfig.BOT_PLACE_DELAY

local function Accumulate(entries)
	for dataId, row in pairs(entries) do
		local acc = totals[dataId] or {
			matches = 0, wins = 0, damageDealt = 0, healed = 0, survived = 0,
		}
		acc.matches += row.matches
		acc.wins += row.wins
		acc.damageDealt += row.damageDealt
		acc.healed += row.healed
		acc.survived += row.survived
		totals[dataId] = acc
	end
end

local function Report()
	local rows = {}
	for dataId, acc in pairs(totals) do
		local data = HeroData.GetById(dataId)
		local matches = math.max(acc.matches, 1)
		table.insert(rows, {
			name = data and data.name or ("#" .. dataId),
			matches = acc.matches,
			winRate = acc.wins / matches,
			damage = acc.damageDealt / matches,
			healed = acc.healed / matches,
			survival = acc.survived / matches,
		})
	end

	table.sort(rows, function(a, b) return a.winRate > b.winRate end)

	local lines = {
		("SIMULACAO — %d partidas bot vs bot"):format(finished),
		("%-10s %7s %8s %8s %8s %8s"):format(
			"HEROI", "JOGOS", "VITOR.", "DANO/J", "CURA/J", "SOBREV."),
	}

	for _, row in ipairs(rows) do
		table.insert(lines, ("%-10s %7d %7.1f%% %8.1f %8.1f %7.1f%%"):format(
			row.name, row.matches, row.winRate * 100,
			row.damage, row.healed, row.survival * 100))
	end

	return table.concat(lines, "\n")
end

local StartOne

local function OnFinished()
	finished += 1

	if finished % 10 == 0 then
		print(("BalanceSim: %d/%d partidas."):format(finished, TOTAL_MATCHES))
	end

	if finished >= TOTAL_MATCHES then
		GameConfig.BOT_PLACE_DELAY = originalPlaceDelay
		print(Report())
	else
		StartOne()
	end
end

function StartOne()
	if started >= TOTAL_MATCHES then return end
	started += 1

	local ok = MatchManager.StartMatch(nil, nil, nil, nil, {
		botVsBot = true,
		onStats = Accumulate,
		onFinish = OnFinished,
	})

	if not ok then
		started -= 1
		task.delay(2, StartOne)
	end
end

GameConfig.BOT_PLACE_DELAY = 0
print(("BalanceSim: rodando %d partidas, %d por vez."):format(TOTAL_MATCHES, CONCURRENT))

for _ = 1, CONCURRENT do
	StartOne()
end
