--[[
	LeaderboardService.lua
	ModuleScript — ServerScriptService/Modules/LeaderboardService

	Ranking global de vitórias, persistido entre servidores via OrderedDataStore.
	Conta vitória em qualquer modo (bot ou PvP) — só não conta pro lado "BOT"
	em si, que nunca chama RecordWin.

	Requer "Enable Studio Access to API Services" (Game Settings > Security)
	pra funcionar dentro do Studio. Sem isso, os pcall abaixo falham
	silenciosamente (só um warn) e o ranking fica vazio — não quebra o jogo.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local LeaderboardService = {}

local WINS_STORE_NAME = "HeroTactics_Wins_v1"
local winsStore = DataStoreService:GetOrderedDataStore(WINS_STORE_NAME)

local updatedEvent = Instance.new("BindableEvent")
LeaderboardService.Updated = updatedEvent.Event

-- userId numérico do vencedor. Nunca chamar pro lado bot.
function LeaderboardService.RecordWin(userId)
	if type(userId) ~= "number" then return end

	local key = tostring(userId)
	local ok, err = pcall(function()
		winsStore:UpdateAsync(key, function(oldValue)
			return (oldValue or 0) + 1
		end)
	end)

	if ok then
		updatedEvent:Fire()
	else
		warn("LeaderboardService: falha ao salvar vitória de " .. key .. ": " .. tostring(err))
	end
end

-- Retorna { {userId, name, wins}, ... } ordenado do maior pro menor
function LeaderboardService.GetTop(count)
	local ok, pages = pcall(function()
		return winsStore:GetSortedAsync(false, count)
	end)

	if not ok then
		warn("LeaderboardService: falha ao buscar ranking: " .. tostring(pages))
		return {}
	end

	local page = pages:GetCurrentPage()
	local result = {}

	for _, entry in ipairs(page) do
		local userId = tonumber(entry.key)
		local name = "Jogador " .. tostring(userId)

		local nameOk, nameResult = pcall(function()
			return Players:GetNameFromUserIdAsync(userId)
		end)
		if nameOk and nameResult then name = nameResult end

		table.insert(result, { userId = userId, name = name, wins = entry.value })
	end

	return result
end

return LeaderboardService
