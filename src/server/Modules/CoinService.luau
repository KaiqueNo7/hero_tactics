--[[
	CoinService.lua
	ModuleScript — ServerScriptService/Modules/CoinService

	Carteira de moedas do jogador: persiste entre servidores e é creditada pelo
	ProgressionService (vitória e subida de nível).

	Mesma dependência do ProgressionService: precisa de "Enable Studio Access to
	API Services" (Game Settings > Security) pra funcionar dentro do Studio. Sem
	isso os pcall falham com warn e o saldo vale só pra sessão.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local SafeStore = require(ServerScriptService.Modules.SafeStore)

local COIN_STORE_NAME = "HeroTactics_Coins_v1"

local coinStore = DataStoreService:GetDataStore(COIN_STORE_NAME)

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local walletUpdate = remotes:FindFirstChild("WalletUpdate")
if not walletUpdate then
	walletUpdate = Instance.new("RemoteEvent")
	walletUpdate.Name = "WalletUpdate"
	walletUpdate.Parent = remotes
end

local CoinService = {}

local coins = {} 

local function Push(player, gained)
	if not player or not player.Parent then return end
	walletUpdate:FireClient(player, {
		coins = coins[player.UserId] or 0,
		gained = gained, 
	})
end

local function Load(player)
	local ok, value = SafeStore.Get(coinStore, tostring(player.UserId),
		("leitura de saldo de %s"):format(player.Name))
	if not ok then value = nil end

	if not player.Parent then return end

	coins[player.UserId] = tonumber(value) or 0
	Push(player)
end

function CoinService.Award(userId, amount)
	amount = math.floor(tonumber(amount) or 0)
	if amount <= 0 then return nil end

	local ok, newTotal = SafeStore.Update(coinStore, tostring(userId), function(oldValue)
		return (tonumber(oldValue) or 0) + amount
	end, ("crédito de %d moedas em %s"):format(amount, tostring(userId)))

	if not (ok and newTotal) then return nil end

	coins[userId] = newTotal

	local player = Players:GetPlayerByUserId(userId)
	if player then Push(player, amount) end

	return newTotal
end

function CoinService.GetCoins(userId)
	return coins[userId] or 0
end

function CoinService.Spend(userId, amount)
	amount = math.floor(tonumber(amount) or 0)
	if amount <= 0 then return false, nil end

	local ok, newTotal = SafeStore.Update(coinStore, tostring(userId), function(oldValue)
		local saldo = tonumber(oldValue) or 0
		if saldo < amount then return nil end
		return saldo - amount
	end, ("débito de %d moedas em %s"):format(amount, tostring(userId)))

	if not ok then
		warn(("CoinService: débito de %d de %s não gravou — compra recusada.")
			:format(amount, tostring(userId)))
		return false, nil
	end
	if not newTotal then return false, nil end

	coins[userId] = newTotal

	local player = Players:GetPlayerByUserId(userId)
	if player then Push(player) end

	return true, newTotal
end

Players.PlayerAdded:Connect(function(player)
	task.spawn(Load, player)
end)

Players.PlayerRemoving:Connect(function(player)
	coins[player.UserId] = nil
end)

for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(Load, player)
end

return CoinService
