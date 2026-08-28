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

-- Dono do jogo. Sempre tem tudo liberado, sem depender de rede.
DevAccess.OWNER_USER_ID = 7867066492

-- Amigos do dono no Roblox entram com o catálogo inteiro. É o jeito de convidar
-- alguém pra testar sem editar código nem republicar: adiciona como amigo no
-- Roblox e pronto; removeu da lista de amigos, perdeu o acesso.
--
-- DESLIGUE ISTO NO LANÇAMENTO. Enquanto for true, TODO amigo seu pula a
-- progressão inteira — ótimo em teste, ruim no jogo publicado, onde essas
-- pessoas nunca veriam os heróis sendo liberados e ainda enfrentariam
-- adversários com acesso diferente do delas.
DevAccess.UNLOCK_FOR_OWNER_FRIENDS = true

-- Testadores fixos por id, pra quem não está na lista de amigos. Some daqui e
-- perde o acesso na próxima entrada no servidor.
DevAccess.EXTRA_TESTER_IDS = {
	-- [123456789] = true,
}

-- [userId] = true/false já resolvido nesta sessão. IsFriendsWith é ida à API do
-- Roblox: sem cache seria uma consulta por partida criada, e ela ainda tem
-- limite de taxa.
local cache = {}

local function ResolveAccess(player)
	local userId = player.UserId

	if userId == DevAccess.OWNER_USER_ID then return true end
	if DevAccess.EXTRA_TESTER_IDS[userId] then return true end
	if not DevAccess.UNLOCK_FOR_OWNER_FRIENDS then return false end
	if DevAccess.OWNER_USER_ID <= 0 then return false end

	-- IsFriendsWith cede e pode estourar (rede fora, limite de taxa). Falhar
	-- aqui não pode derrubar a entrada do jogador nem a criação da partida:
	-- no erro ele entra como jogador normal, que é o lado seguro de errar.
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

-- Resolve e guarda. Roda no PlayerAdded pra que a resposta já esteja pronta
-- quando a partida for criada.
function DevAccess.Preload(player)
	if not player or not player.Parent then return end
	cache[player.UserId] = ResolveAccess(player)
end

-- NÃO cede: é chamado no meio da criação da partida, onde ceder abriria brecha
-- pro estado mudar embaixo. Se o Preload ainda não voltou (jogador entrou e
-- começou a partida no mesmo segundo), responde "jogador normal" — o dono não é
-- afetado por isso, porque o id dele é checado direto, sem rede.
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

-- o módulo pode ser exigido depois de alguém já ter entrado (Studio, hot reload)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(DevAccess.Preload, player)
end

return DevAccess
