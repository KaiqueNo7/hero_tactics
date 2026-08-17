--[[
	ProgressionService.lua
	ModuleScript — ServerScriptService/Modules/ProgressionService

	XP acumulado de cada jogador, persistido entre servidores. Guarda só o total;
	o nível sai da curva em ReplicatedStorage.Modules.Progression.

	Requer "Enable Studio Access to API Services" (Game Settings > Security) pra
	funcionar dentro do Studio. Sem isso os pcall abaixo falham com um warn e o
	jogo segue com o XP só da sessão — nada quebra, mas nada persiste.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Progression = require(ReplicatedStorage.Modules.Progression)
local SafeStore = require(ServerScriptService.Modules.SafeStore)

local XP_STORE_NAME = "HeroTactics_Xp_v1"
local xpStore = DataStoreService:GetDataStore(XP_STORE_NAME)

-- Os outros remotes são feitos à mão no place; este é criado aqui se faltar,
-- pra quem clonar o repo não precisar montar o RemoteEvent na mão.
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local profileUpdate = remotes:FindFirstChild("ProfileUpdate")
if not profileUpdate then
	profileUpdate = Instance.new("RemoteEvent")
	profileUpdate.Name = "ProfileUpdate"
	profileUpdate.Parent = remotes
end

local ProgressionService = {}

local totalXp = {} -- [userId] = XP acumulado conhecido nesta sessão

local function Push(player, gained)
	if not player or not player.Parent then return end

	local info = Progression.FromTotalXp(totalXp[player.UserId] or 0)
	info.gained = gained -- nil quando é só o estado inicial, sem ganho novo
	profileUpdate:FireClient(player, info)
end

local function Load(player)
	local ok, value = SafeStore.Get(xpStore, tostring(player.UserId),
		("leitura de XP de %s"):format(player.Name))
	if not ok then value = nil end

	-- se o jogador saiu enquanto o GetAsync rodava, não deixa lixo no cache
	if not player.Parent then return end

	totalXp[player.UserId] = tonumber(value) or 0
	Push(player)
end

-- result: "win" | "loss" | "draw". survivors só pesa na vitória.
-- Cede (UpdateAsync), então chame de dentro de um task.spawn se estiver no meio
-- da resolução de uma partida.
function ProgressionService.AwardMatchXp(player, result, survivors, vsBot)
	if not player then return end

	local amount = Progression.MatchReward(result, survivors, vsBot)
	if amount <= 0 then return end

	local userId = player.UserId

	-- UpdateAsync soma em cima do que está gravado: mesmo que o GetAsync do
	-- login tenha falhado, o ganho não apaga o histórico do jogador. O SafeStore
	-- ainda tenta de novo algumas vezes antes de desistir — perder o XP de uma
	-- partida inteira por um soluço de rede é o tipo de coisa que faz o jogador
	-- achar que o jogo não guarda progresso.
	local ok, newTotal = SafeStore.Update(xpStore, tostring(userId), function(oldValue)
		return (tonumber(oldValue) or 0) + amount
	end, ("gravação de XP de %s"):format(player.Name))

	if ok and newTotal then
		totalXp[userId] = newTotal
	else
		-- sem persistir: pelo menos a sessão atual mostra o que ganhou
		totalXp[userId] = (totalXp[userId] or 0) + amount
	end

	Push(player, amount)
end

function ProgressionService.GetTotalXp(userId)
	return totalXp[userId] or 0
end

-- Nível atual pela curva. Se o GetAsync do login ainda não voltou (ou falhou), o
-- cache está em 0 e isto devolve 1 — o jogador entra com o elenco inicial em vez
-- de travar a partida. Vale saber que é assim: um soluço de DataStore no login
-- não bloqueia ninguém, só esconde os heróis avançados naquela partida.
function ProgressionService.GetLevel(userId)
	return Progression.FromTotalXp(ProgressionService.GetTotalXp(userId)).level
end

Players.PlayerAdded:Connect(function(player)
	task.spawn(Load, player)
end)

Players.PlayerRemoving:Connect(function(player)
	totalXp[player.UserId] = nil
end)

-- o módulo pode ser exigido depois de alguém já ter entrado (Studio, hot reload)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(Load, player)
end

return ProgressionService
