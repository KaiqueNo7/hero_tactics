--[[
	DevAccess.lua
	ModuleScript — ServerScriptService/Modules/DevAccess

	Quem enxerga o catálogo inteiro sem passar pela liberação por nível: o dono e
	os testadores.

	Mora no servidor, e não junto do HeroData em ReplicatedStorage, por dois
	motivos. IsFriendsWith é chamada de rede e a resposta é autoridade — o
	cliente não pode opinar sobre quem é testador. E a separação é conceitual: o
	HeroData guarda a REGRA (que nível libera o quê), aqui ficam as EXCEÇÕES à
	regra. Mexer numa não mexe na outra.

	O cliente não precisa saber nada disto: o servidor manda no snapshot a lista
	de heróis bloqueados já resolvida, que pra um testador chega vazia.
]]

local Players = game:GetService("Players")

local DevAccess = {}

DevAccess.OWNER_USER_ID = 7867066492
DevAccess.UNLOCK_FOR_OWNER_FRIENDS = true
DevAccess.EXTRA_TESTER_IDS = {
	-- [123456789] = true,
}

local cache = {}

local function ResolveAccess(player)
	local userId = player.UserId

	if userId == DevAccess.OWNER_USER_ID then return true end
	if DevAccess.EXTRA_TESTER_IDS[userId] then return true end
	if not DevAccess.UNLOCK_FOR_OWNER_FRIENDS then return false end
	if DevAccess.OWNER_USER_ID <= 0 then return false end

	local ok, isFriend = pcall(function()
		return player:IsFriendsWith(DevAccess.OWNER_USER_ID)
	end)

	if not ok then
		warn(("DevAccess: IsFriendsWith falhou para %s — tratando como jogador normal")
			:format(player.Name))
		return false
	end

	return isFriend == true
end

function DevAccess.Preload(player)
	if not player or not player.Parent then return end
	cache[player.UserId] = ResolveAccess(player)
end

function DevAccess.HasFullCatalog(player)
	if not player then return false end
	if player.UserId == DevAccess.OWNER_USER_ID then return true end
	if DevAccess.EXTRA_TESTER_IDS[player.UserId] then return true end
	return cache[player.UserId] == true
end

Players.PlayerAdded:Connect(function(player)
	task.spawn(DevAccess.Preload, player)
end)

Players.PlayerRemoving:Connect(function(player)
	cache[player.UserId] = nil
end)

for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(DevAccess.Preload, player)
end

return DevAccess
