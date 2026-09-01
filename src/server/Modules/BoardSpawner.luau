--[[
	BoardSpawner.lua
	ModuleScript — ServerScriptService/Modules/BoardSpawner
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local HexGrid = require(ReplicatedStorage.Modules.HexGrid)
local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local HeroData = require(ReplicatedStorage.Modules.HeroData)
local Arenas = require(ReplicatedStorage.Modules.Arenas)
local LightingSetup = require(script.Parent.LightingSetup)
local ArenaBuilder = require(script.Parent.ArenaBuilder)

local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")

local BoardSpawner = {}

-- ===== AJUSTE FINO =====
local HEX_RADIUS = 6
local TILE_FILL = 0.94
local TILE_THICKNESS = 1

-- A arena do slot é levantada do zero a cada partida, a partir do tema dela
-- (ver Arenas). Guardar a montada e reaproveitá-la quando o tema batia
-- economizava uns milissegundos e cobrava caro: mexer no builder não aparecia
-- até alguém apagar a pasta na mão.
--
-- Cenário montado à mão continua ganhando do código: uma pasta chamada
-- ArenaMaster_<tema> no Workspace é clonada e alinhada no lugar do diorama
-- gerado. É o mesmo acordo do LobbyZoneBuilder — o construtor entrega a
-- primeira versão e sai da frente.
local ARENA_SLOT_PREFIX = "ArenaSlot_"
local ARENA_MASTER_PREFIX = "Arena_"
local LEGACY_STORE = "LegacyArenas"

local function ArenaFolderName(slot)
	return ARENA_SLOT_PREFIX .. slot
end

local function BoardFolderName(slot)
	return "Board_" .. slot
end

-- ===== CONFIG =====
local POINTY_TO_FLAT_ROTATION = 30
local COLOR_A = GameConfig.HEX_COLOR_A
local COLOR_B = GameConfig.HEX_COLOR_B

local function ApplyColor(instance, color)
	if instance:IsA("BasePart") then
		if instance:IsA("UnionOperation") then
			instance.UsePartColor = true
		end
		instance.Color = color
	elseif instance:IsA("Model") then
		for _, descendant in ipairs(instance:GetDescendants()) do
			ApplyColor(descendant, color)
		end
	end
end

local function CreateHexTile(template, worldPos, color, hexId)
	local clone = template:Clone()
	local tileRadius = HEX_RADIUS * TILE_FILL

	local tileSize = Vector3.new(
		math.sqrt(3) * tileRadius,
		TILE_THICKNESS,
		2 * tileRadius
	)

	local targetCFrame = CFrame.new(worldPos)
		* CFrame.Angles(0, math.rad(POINTY_TO_FLAT_ROTATION), 0)

	if clone:IsA("Model") then
		if not clone.PrimaryPart then
			local firstPart = clone:FindFirstChildWhichIsA("BasePart", true)
			if firstPart then
				clone.PrimaryPart = firstPart
			end
		end
		clone:PivotTo(targetCFrame)
	else
		clone.Size = tileSize
		clone.CFrame = targetCFrame
		clone.Anchored = true
		clone.CanCollide = true
	end

	if clone:IsA("BasePart") then
		clone.CastShadow = false
	end
	for _, descendant in ipairs(clone:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.CastShadow = false
		end
	end

	clone.Name = hexId
	clone:SetAttribute("HexId", hexId)
	clone:SetAttribute("BaseColor", color)
	ApplyColor(clone, color)

	-- Aqui existiam duas sobras de depuração, uma por casa: um BillboardGui
	-- "HexLabel" SEM NENHUM FILHO e um ClickDetector cujo único handler era um
	-- print. Nenhum código lia os dois.
	--
	-- Não era inofensivo: BillboardGui é reprojetado todo quadro mesmo vazio, e
	-- ClickDetector entra no teste de mouse do engine. Com 61 casas por arena e
	-- até 6 arenas simultâneas, dava ~366 BillboardGui vazios e ~366
	-- ClickDetectors sendo processados por quadro, sem desenhar nada.
	--
	-- Quem lê o clique é o cliente, pelo atributo HexId em mouse.Target — nunca
	-- foi por ClickDetector.

	return clone
end

local function ParkLegacyArena(slot)
	local legacy = Workspace:FindFirstChild(slot <= 1 and "Arena" or ("Arena_" .. slot))
	if not legacy or legacy:GetAttribute("Theme") then return end

	local store = ServerStorage:FindFirstChild(LEGACY_STORE)
	if not store then
		store = Instance.new("Folder")
		store.Name = LEGACY_STORE
		store.Parent = ServerStorage
	end

	legacy.Parent = store
	print(("BoardSpawner: %s guardada em ServerStorage.%s — as arenas agora vêm de Arenas.THEMES. Pra usá-la como cenário de uma região, renomeie pra ArenaMaster_<tema> e devolva ao Workspace.")
		:format(legacy.Name, LEGACY_STORE))
end

function BoardSpawner.MasterFor(theme)
	local name = theme.master or (ARENA_MASTER_PREFIX .. theme.id)
	return Workspace:FindFirstChild(name, true), name
end

-- Levanta a arena do TEMA pedido no slot, derrubando a que estiver lá. É o que
-- faz a partida seguinte no mesmo slot acontecer noutra região.
function BoardSpawner.EnsureArena(slot, theme)
	slot = slot or 1
	theme = theme or Arenas.THEMES[1]

	HexGrid.SetHexSize(HEX_RADIUS)
	HexGrid.Generate()

	ParkLegacyArena(slot)

	local name = ArenaFolderName(slot)
	local existing = Workspace:FindFirstChild(name)
	if existing then existing:Destroy() end

	local origin = GameConfig.ArenaOrigin(slot)
	local master, masterName = BoardSpawner.MasterFor(theme)

	local folder = master and ArenaBuilder.CloneMaster(master, theme, origin, name)
	if folder then
		print(("BoardSpawner: %s clonada de %s."):format(name, master:GetFullName()))
	else
		warn(("BoardSpawner: %s montada por codigo — nao achei %s no Workspace. Cenario feito a mao no Studio NAO vai aparecer nesta arena.")
			:format(name, masterName))
		folder = ArenaBuilder.Build(theme, origin, name)
	end

	LightingSetup.LightArena(folder)

	return folder
end

local function FocusInStudio(folder)
	if not (folder and RunService:IsEdit()) then return end

	local floor = folder:FindFirstChild("Floor", true)
	local camera = Workspace.CurrentCamera
	if not (floor and floor:IsA("BasePart") and camera) then return end

	camera.FieldOfView = GameConfig.CAMERA_FOV
	camera.CFrame = GameConfig.MatchCameraCFrame(floor.Position)
end

-- ===== EDITAR UMA ARENA À MÃO =====
-- Ponto de partida pra trabalhar a região no Studio, em modo Edit:
--
--     require(game.ServerScriptService.Modules.BoardSpawner).BuildMaster("geleira")
--     require(game.ServerScriptService.Modules.BoardSpawner).BuildAllMasters()
--
-- Ele levanta o diorama do tema numa área livre (depois do último slot de
-- partida, pra não cair em cima de ninguém), junto com um tabuleiro de
-- referência pra alinhar decoração, e deixa a pasta como ArenaMaster_<tema>.
-- Dali em diante é seu: mova, apague, acrescente o que quiser e SALVE O PLACE —
-- toda partida daquela região passa a clonar o que ficou lá em vez de gerar de
-- novo. O alinhamento sai da peça `Floor`, então a arena pode morar em qualquer
-- canto do Workspace.
--
-- Rodar de novo MANTÉM o que você editou e não gera nada por cima, igual ao
-- LobbyZoneBuilder adotando a trilha do place. `BuildMaster(tema, true)` é a
-- saída explícita que descarta a mão e volta pro gerado.
function BoardSpawner.BuildMaster(themeId, force)
	local theme = Arenas.ById(themeId)
	if not theme then
		warn(("BoardSpawner: nao existe tema '%s' em Arenas.THEMES."):format(tostring(themeId)))
		return nil
	end

	local previous, masterName = BoardSpawner.MasterFor(theme)
	if previous and not force then
		print(("BoardSpawner: %s ja existe — mantido como esta. BuildMaster('%s', true) descarta e gera de novo.")
			:format(masterName, theme.id))
		FocusInStudio(previous)
		return previous
	end

	if previous then
		previous:Destroy()
		warn(("BoardSpawner: %s anterior descartado — o que estava montado à mão foi junto."):format(masterName))
	end

	local slot = GameConfig.MAX_LIVE_MATCHES + (table.find(Arenas.THEMES, theme) or 1)
	BoardSpawner.SpawnBoard(slot, false, nil, theme)

	local folder = Workspace:FindFirstChild(ArenaFolderName(slot))
	if folder then folder.Name = masterName end

	print(("BoardSpawner: %s pronto em %s. Edite, salve o place, e as partidas da regiao passam a clonar ele. O Board_%d ao lado e so referencia de alinhamento — pode apagar.")
		:format(masterName, tostring(GameConfig.ArenaOrigin(slot)), slot))

	FocusInStudio(folder)
	return folder
end

function BoardSpawner.ReportMasters()
	for _, theme in ipairs(Arenas.THEMES) do
		local master, name = BoardSpawner.MasterFor(theme)
		if master then
			print(("BoardSpawner: %s -> %s"):format(theme.id, master:GetFullName()))
		else
			warn(("BoardSpawner: %s -> SEM TEMPLATE (esperado um Model/Folder chamado %s no Workspace)")
				:format(theme.id, name))
		end
	end
end


function BoardSpawner.BuildAllMasters(force)
	local folders, first = {}, nil
	for _, theme in ipairs(Arenas.THEMES) do
		local folder = BoardSpawner.BuildMaster(theme.id, force)
		folders[theme.id] = folder
		first = first or folder
	end

	FocusInStudio(first)
	return folders
end

-- ===== O ADVERSÁRIO EM PÉ NO SLOT 2 =====
-- Num confronto da campanha quem fica ali é o HERÓI que dá nome ao confronto,
-- com o sprite dele: o jogador olha pro outro lado do campo e vê CONTRA QUEM
-- está jogando, em vez do mesmo boneco genérico nos onze confrontos. O treino
-- livre (sem confronto definido) continua com o boneco.
--
-- Sprite chapado, e não modelo 3D: é assim que os heróis já aparecem no
-- tabuleiro, no draft e na ficha — um boneco 3D seria o único lugar do jogo em
-- que o mesmo personagem tem outra forma.
local STAND_SPRITE_HEIGHT = 11 -- studs; na mesma ordem de grandeza do boneco em PLAYER_STAND_SCALE
local STAND_SPRITE_WIDTH = 8

local function SpawnHeroStand(boardFolder, origin, data)
	local anchor = Instance.new("Part")
	anchor.Name = "BotDummy" -- mesmo nome do boneco: quem procurava, continua achando
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false

	local floorY = origin.Y - 0.5 -- mesmo piso do boneco, logo abaixo
	anchor.Position = HexGrid.GetStandPosition(2, floorY + STAND_SPRITE_HEIGHT / 2, origin)

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "HeroStand"
	-- Size em SCALE numa BillboardGui é medido em STUDS: o sprite tem tamanho de
	-- mundo e encolhe com a distância como qualquer coisa do cenário, em vez de
	-- ficar do mesmo tamanho na tela.
	billboard.Size = UDim2.fromScale(STAND_SPRITE_WIDTH, STAND_SPRITE_HEIGHT)
	billboard.AlwaysOnTop = false
	billboard.Parent = anchor

	local image = Instance.new("ImageLabel")
	image.Size = UDim2.fromScale(1, 1)
	image.BackgroundTransparency = 1
	image.ScaleType = Enum.ScaleType.Fit
	image.ResampleMode = Enum.ResamplerMode.Pixelated
	image.Parent = billboard

	local spriteId = HeroData.GetSpriteId(data)
	if spriteId then
		image.Image = spriteId
		image.ImageRectSize = HeroData.GetFrameSize(data)
		image.ImageRectOffset = HeroData.GetFrameOffset(data)
	else
		image.BackgroundTransparency = 0
		image.BackgroundColor3 = data.color
	end

	anchor.Parent = boardFolder
end

-- Bonequin do bot no slot 2, ao lado do jogador. Em PvP o slot 2 é o outro
-- jogador de verdade, então o bonequin nem é criado.
local function SpawnBotDummy(boardFolder, origin, botDataId)
	local data = botDataId and HeroData.GetById(botDataId)
	if data then
		SpawnHeroStand(boardFolder, origin, data)
		return
	end

	local template = ReplicatedStorage:FindFirstChild("BotDummyTemplate")
	local source = template and template:FindFirstChildWhichIsA("Model")
	if not source then return end

	local dummy = source:Clone()
	dummy.Name = "BotDummy"

	-- Mesma escala do jogador local (o CameraController aplica esta constante no
	-- avatar dele): os dois ficam frente a frente, e um do tamanho do outro é o
	-- mínimo pro duelo ler como duelo. Antes só o jogador crescia e o bot ficava
	-- um boneco miúdo do outro lado do campo.
	pcall(function()
		dummy:ScaleTo(GameConfig.PLAYER_STAND_SCALE)
	end)

	-- A altura vem do MODELO, não de um número fixo. Antes o pivô ia pra
	-- origin.Y + 3, uma conta feita pro boneco de 5 studs que estava ali: trocar
	-- por um avatar mais alto ou mais baixo enterrava os pés no chão ou deixava
	-- ele flutuando. A caixa é medida DEPOIS do ScaleTo — medir antes plantaria
	-- os pés na altura do tamanho velho e o boneco afundaria no piso.
	local _, size = dummy:GetBoundingBox()
	local floorY = origin.Y - 0.5 -- mesmo piso que a arena usa
	local standPos = HexGrid.GetStandPosition(2, floorY + size.Y / 2, origin)
	local lookAt = HexGrid.GetStandFacing(2, standPos)
	dummy:PivotTo(CFrame.new(standPos, lookAt))

	for _, part in ipairs(dummy:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
		end
	end

	dummy.Parent = boardFolder
end

-- A taverna é editada à mão no Studio; GameConfig.ARENA_ORIGIN é um número
-- escrito à mão. Quando alguém move uma e esquece a outra, a partida roda
-- inteira só que o tabuleiro nasce no vazio, longe do cenário — sintoma que
-- custa caro pra diagnosticar e é trivial de detectar aqui.
local function WarnIfOffTheFloor(arena, origin)
	local floor = arena and arena:FindFirstChild("Floor", true)
	if not floor or not floor:IsA("BasePart") then return end

	local center = HexGrid.GetBoardCenter(origin)
	local delta = floor.Position - center

	if math.abs(delta.X) > floor.Size.X / 2
		or math.abs(delta.Z) > floor.Size.Z / 2
		or math.abs(center.Y - (floor.Position.Y + floor.Size.Y / 2)) > 2
	then
		warn(("BoardSpawner: o tabuleiro (centro %s) não cai sobre o piso da %s (%s). "
			.. "Ajuste GameConfig.ARENA_ORIGIN: ele é a origem, e o centro fica em origem + (18, 0, 25.98).")
			:format(tostring(center), arena.Name, tostring(floor.Position)))
	end
end

-- Monta o tabuleiro do slot pedido. withBotDummy = false nas partidas PvP, onde
-- o slot 2 é um jogador de verdade. Devolve o folder pra partida guardar — o
-- cliente recebe essa referência no snapshot e nunca procura "o Board" pelo
-- nome, que com várias partidas seria ambíguo.
-- `botDataId` é o herói do confronto da campanha: é ele que fica de pé do outro
-- lado. Sem ele (treino livre, PvP) o slot 2 recebe o boneco genérico ou nada.
function BoardSpawner.SpawnBoard(slot, withBotDummy, botDataId, theme)
	slot = slot or 1
	theme = theme or Arenas.THEMES[1]

	local template = ReplicatedStorage:FindFirstChild("HexTile")
	if not template then
		error("BoardSpawner: não encontrei 'HexTile' em ReplicatedStorage. Confira o nome exato.")
	end

	local origin = GameConfig.ArenaOrigin(slot)

	HexGrid.SetHexSize(HEX_RADIUS)
	HexGrid.Generate()

	local existing = Workspace:FindFirstChild(BoardFolderName(slot))
	if existing then
		existing:Destroy()
	end

	local boardFolder = Instance.new("Folder")
	boardFolder.Name = BoardFolderName(slot)
	boardFolder.Parent = Workspace

	-- O xadrez veste a região: a Geleira é pedra clara e fria, a Forja é basalto
	-- quente. Só o PAR muda — os dois tons continuam bem separados, senão o
	-- tabuleiro vira uma laje só e ninguém conta distância de bate-pronto.
	local tiles = theme.tiles
	local colorA = tiles and tiles.a or COLOR_A
	local colorB = tiles and tiles.b or COLOR_B

	local allHexes = HexGrid.GetAllHexes()
	for _, hex in ipairs(allHexes) do
		local worldPos = HexGrid.GetWorldPosition(hex.id, origin)
		local color = (hex.col % 2 == 0) and colorA or colorB
		CreateHexTile(template, worldPos, color, hex.id).Parent = boardFolder
	end

	local arena = BoardSpawner.EnsureArena(slot, theme)
	WarnIfOffTheFloor(arena, origin)

	if withBotDummy then
		SpawnBotDummy(boardFolder, origin, botDataId)
	end

	return boardFolder
end

return BoardSpawner
