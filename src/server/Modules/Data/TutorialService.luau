--[[
	TutorialService.lua
	ModuleScript — ServerScriptService/Modules/TutorialService

	Quais lições do tutorial cada jogador já viu, persistido entre servidores.
	Mesmo molde do HeroUnlockService: DataStore + SafeStore, cache por sessão,
	lista gravada em disco e conjunto em memória.

	POR LIÇÃO, e não uma bandeira "tutorial feito". A Casa de Promoção só abre lá
	pelo turno 10 e o Taunt só aparece se alguém levar um herói com Taunt: numa
	bandeira só, tudo que não coubesse na primeira partida nunca mais seria
	ensinado. Por lição, o jogador aprende cada conceito na primeira vez que ele
	ACONTECE — seja na partida 1 ou na 12.

	O CLIENTE É QUEM DIZ QUE VIU, e está tudo bem. É o único remote do jogo onde
	a palavra do cliente é aceita sem conferência, então vale dizer por quê: o
	pior que um pedido forjado faz é pular o próprio tutorial de quem forjou.
	Não dá herói, não dá moeda, não mexe em partida. Validar isso custaria um
	espelho do estado da partida no servidor pra ganhar nada.

	Mesma dependência de DataStore do resto: exige "Enable Studio Access to API
	Services" pra persistir dentro do Studio. Sem isso o SafeStore avisa e o
	tutorial vale só pra sessão — ninguém trava.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Tutorial = require(ReplicatedStorage.Modules.Tutorial)
local SafeStore = require(ServerScriptService.Modules.SafeStore)

local STORE_NAME = "HeroTactics_Tutorial_v1"
local store = DataStoreService:GetDataStore(STORE_NAME)

-- Mesmo padrão do RosterUpdate/ProfileUpdate: criado aqui se faltar, pra quem
-- clonar o repo não precisar montar o remote na mão dentro do place.
local remotes = ReplicatedStorage:WaitForChild("Remotes")

local function EnsureRemote(className, name)
	local existing = remotes:FindFirstChild(name)
	if existing then return existing end

	local created = Instance.new(className)
	created.Name = name
	created.Parent = remotes
	return created
end

local tutorialUpdate = EnsureRemote("RemoteEvent", Tutorial.REMOTE_NAME)

local TutorialService = {}

local seen = {} -- [userId] = { [lessonId] = true }

local function SeenSet(userId)
	return seen[userId] or {}
end

local function Push(player)
	if not player or not player.Parent then return end

	local ids = {}
	for lessonId in pairs(SeenSet(player.UserId)) do
		table.insert(ids, lessonId)
	end
	table.sort(ids)

	tutorialUpdate:FireClient(player, { seen = ids })
end

local function Load(player)
	local ok, value = SafeStore.Get(store, tostring(player.UserId),
		("leitura do tutorial de %s"):format(player.Name))
	if not ok then value = nil end

	-- saiu enquanto o GetAsync rodava: não deixa lixo no cache
	if not player.Parent then return end

	local set = {}
	if type(value) == "table" then
		for _, lessonId in ipairs(value) do
			-- Só ids que EXISTEM hoje. Lição removida do Tutorial.LESSONS ficaria
			-- guardada pra sempre engordando a chave, e uma renomeada voltaria a
			-- aparecer de qualquer jeito — filtrar aqui mantém o disco limpo.
			if Tutorial.GetLesson(lessonId) then set[lessonId] = true end
		end
	end

	seen[player.UserId] = set
	Push(player)
end

-- ===================== REGISTRO =====================
-- IDEMPOTENTE, como o Unlock: repetir uma lição já vista sai sem gravar nada. O
-- cliente pode reenviar depois de uma reconexão, e isso não pode virar uma
-- escrita de DataStore por quadro.
function TutorialService.MarkSeen(player, lessonId)
	if not player then return end
	if type(lessonId) ~= "string" then return end
	if not Tutorial.GetLesson(lessonId) then return end

	local userId = player.UserId
	if SeenSet(userId)[lessonId] then return end

	local set = seen[userId] or {}
	set[lessonId] = true
	seen[userId] = set -- vale já nesta sessão, mesmo que o disco falhe abaixo

	local ids = {}
	for id in pairs(set) do table.insert(ids, id) end
	table.sort(ids)

	-- Sem `if not stored then desfaz` (o HeroUnlockService faz isso pra herói).
	-- Aqui a assimetria é de propósito: se a gravação falhar, o pior é a lição
	-- voltar no próximo login. Reverter o cache faria ela reaparecer AGORA, no
	-- meio da mesma partida, que é bem pior.
	SafeStore.Update(store, tostring(userId), function()
		return ids
	end, ("gravação do tutorial de %s"):format(player.Name))
end

function TutorialService.HasSeen(player, lessonId)
	return player ~= nil and SeenSet(player.UserId)[lessonId] == true
end

-- O REMOTE É LIGADO DE FORA, no GameStartTrigger, junto dos outros. Não é só
-- gosto: `OnServerEvent:Connect` estoura fora de um servidor de verdade ("can
-- only be used on the server"), e um Connect no corpo do módulo tornava o
-- arquivo inteiro impossível de exigir em modo Edit — nem pra testar o
-- MarkSeen. Sem ele, o módulo carrega em qualquer lugar e só o Script precisa
-- de servidor.
Players.PlayerAdded:Connect(function(player)
	task.spawn(Load, player)
end)

Players.PlayerRemoving:Connect(function(player)
	seen[player.UserId] = nil
end)

-- o módulo pode ser exigido depois de alguém já ter entrado (Studio, hot reload)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(Load, player)
end

return TutorialService
