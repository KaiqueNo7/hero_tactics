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

-- Mesmo padrão do ProfileUpdate: criado aqui se faltar, pra quem clonar o repo
-- não precisar montar o RemoteEvent na mão dentro do place.
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local walletUpdate = remotes:FindFirstChild("WalletUpdate")
if not walletUpdate then
	walletUpdate = Instance.new("RemoteEvent")
	walletUpdate.Name = "WalletUpdate"
	walletUpdate.Parent = remotes
end

local CoinService = {}

local coins = {} -- [userId] = saldo conhecido nesta sessão

local function Push(player, gained)
	if not player or not player.Parent then return end
	walletUpdate:FireClient(player, {
		coins = coins[player.UserId] or 0,
		gained = gained, -- nil quando é só o estado inicial, sem ganho novo
	})
end

local function Load(player)
	local ok, value = SafeStore.Get(coinStore, tostring(player.UserId),
		("leitura de saldo de %s"):format(player.Name))
	if not ok then value = nil end

	-- saiu enquanto o GetAsync rodava: não deixa lixo no cache
	if not player.Parent then return end

	coins[player.UserId] = tonumber(value) or 0
	Push(player)
end

-- Credita e devolve o novo saldo, ou nil se não deu pra gravar. Escreve direto
-- pelo userId, então funciona mesmo se o jogador já tiver saído — o recibo
-- precisa ser honrado de qualquer jeito.
function CoinService.Award(userId, amount)
	amount = math.floor(tonumber(amount) or 0)
	if amount <= 0 then return nil end

	-- Aqui a nova tentativa vale ainda mais que no XP: isto roda dentro do
	-- crédito, e desistir na primeira falha é moeda ganha que some.
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

-- Debita `amount` se houver saldo. Devolve (ok, novoSaldo).
--
-- A checagem do saldo mora DENTRO do transform, não antes dele: entre um
-- GetAsync e um SetAsync cabem duas compras do mesmo jogador em servidores
-- diferentes, e as duas passariam achando que o dinheiro estava lá. Quem decide
-- é o UpdateAsync, que lê e escreve como uma operação só.
--
-- Devolver nil do transform ABORTA a gravação — é assim que a compra sem saldo
-- termina sem encostar no valor guardado.
function CoinService.Spend(userId, amount)
	amount = math.floor(tonumber(amount) or 0)
	if amount <= 0 then return false, nil end

	local ok, newTotal = SafeStore.Update(coinStore, tostring(userId), function(oldValue)
		local saldo = tonumber(oldValue) or 0
		if saldo < amount then return nil end
		return saldo - amount
	end, ("débito de %d moedas em %s"):format(amount, tostring(userId)))

	-- ok=true com newTotal nil é o transform tendo abortado: tinha conexão, mas
	-- não tinha saldo. ok=false é o DataStore fora do ar. Pro chamador as duas
	-- terminam igual (a compra não aconteceu), mas só a segunda merece log.
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

-- o módulo pode ser exigido depois de alguém já ter entrado (Studio, hot reload)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(Load, player)
end

return CoinService
