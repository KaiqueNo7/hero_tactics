--[[
	BoardSpawner.lua
	ModuleScript — ServerScriptService/Modules/BoardSpawner
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local HexGrid = require(ReplicatedStorage.Modules.HexGrid)
local GameConfig = require(ReplicatedStorage.Modules.GameConfig)

local BoardSpawner = {}

-- ===== AJUSTE FINO =====
local HEX_RADIUS = 6
local TILE_FILL = 0.94
local TILE_THICKNESS = 1
local ARENA_OFFSET = GameConfig.ArenaOrigin(1)

-- O cenário mora fora do folder Board (que é destruído a cada partida) e
-- PERSISTE no place. Assim dá pra ver e personalizar a taverna no Studio sem
-- dar play, e o que você editar continua lá — o código só constrói se faltar.
--
-- Com várias partidas ao mesmo tempo, a arena do slot 1 é a original (a que
-- você edita à mão) e as dos slots seguintes são CLONES dela, deslocados no X.
-- É de propósito: assim o layout é literalmente o mesmo em todas, e qualquer
-- móvel que você mudar na primeira aparece nas outras na próxima partida.
local ARENA_FOLDER_NAME = "Arena"

local function ArenaFolderName(slot)
	return slot <= 1 and ARENA_FOLDER_NAME or (ARENA_FOLDER_NAME .. "_" .. slot)
end

local function BoardFolderName(slot)
	return "Board_" .. slot
end

-- ===== CONFIG =====
local POINTY_TO_FLAT_ROTATION = 30
local COLOR_A = Color3.fromRGB(120, 170, 220)
local COLOR_B = Color3.fromRGB(90, 130, 180)

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

-- ===== CENÁRIO (TAVERNA) =====
-- A câmera fica em +Z olhando pra -Z, acima do tabuleiro. Por isso a taverna
-- não tem teto nem parede da frente: seria tudo entre a câmera e o jogo.
-- É um diorama — três paredes, piso de tábuas e tralha nas bordas.
local TAVERN_WALL_HEIGHT = 30
local TAVERN_WALL_THICKNESS = 2
local TAVERN_MARGIN_LEFT = 34 -- lado onde player e bonequin ficam de pé
local TAVERN_MARGIN_RIGHT = 18
local TAVERN_MARGIN_BACK = 18
local TAVERN_MARGIN_FRONT = 24

local WOOD_FLOOR = Color3.fromRGB(94, 62, 38)
local WOOD_DARK = Color3.fromRGB(62, 41, 26)
local WOOD_TRIM = Color3.fromRGB(126, 86, 50)
local STONE_GREY = Color3.fromRGB(92, 88, 82)

local function MakePart(props, parent)
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false

	for key, value in pairs(props) do
		part[key] = value
	end

	part.Parent = parent
	return part
end

-- Cilindro do Roblox nasce deitado no eixo X; girar 90° em Z põe ele de pé
local function StandingCylinder(props, parent)
	props.Shape = Enum.PartType.Cylinder
	props.CFrame = props.CFrame * CFrame.Angles(0, 0, math.rad(90))
	return MakePart(props, parent)
end

local function BuildBarrel(parent, position)
	local height = 5.5
	local base = CFrame.new(position + Vector3.new(0, height / 2, 0))

	StandingCylinder({
		Name = "Barrel",
		Size = Vector3.new(height, 5, 5),
		CFrame = base,
		Color = WOOD_DARK,
		Material = Enum.Material.WoodPlanks,
	}, parent)

	for _, offset in ipairs({ -1.4, 1.4 }) do
		StandingCylinder({
			Name = "BarrelRing",
			Size = Vector3.new(0.7, 5.3, 5.3),
			CFrame = base * CFrame.new(0, offset, 0),
			Color = Color3.fromRGB(68, 60, 50),
			Material = Enum.Material.Metal,
		}, parent)
	end
end

local function BuildTable(parent, position)
	StandingCylinder({
		Name = "TableTop",
		Size = Vector3.new(0.9, 10, 10),
		CFrame = CFrame.new(position + Vector3.new(0, 6.5, 0)),
		Color = WOOD_TRIM,
		Material = Enum.Material.Wood,
	}, parent)

	MakePart({
		Name = "TableLeg",
		Size = Vector3.new(1.6, 6.5, 1.6),
		CFrame = CFrame.new(position + Vector3.new(0, 3.25, 0)),
		Color = WOOD_DARK,
		Material = Enum.Material.Wood,
	}, parent)

	MakePart({
		Name = "TableFoot",
		Size = Vector3.new(5, 0.6, 5),
		CFrame = CFrame.new(position + Vector3.new(0, 0.3, 0)),
		Color = WOOD_DARK,
		Material = Enum.Material.Wood,
	}, parent)
end

local function BuildTorch(parent, position, faceDirection)
	MakePart({
		Name = "TorchBracket",
		Size = Vector3.new(0.8, 4, 0.8),
		CFrame = CFrame.new(position),
		Color = Color3.fromRGB(48, 44, 40),
		Material = Enum.Material.Metal,
	}, parent)

	local flame = MakePart({
		Name = "TorchFlame",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(1.8, 1.8, 1.8),
		CFrame = CFrame.new(position + Vector3.new(0, 2.4, 0) + faceDirection * 0.4),
		Color = Color3.fromRGB(255, 170, 70),
		Material = Enum.Material.Neon,
	}, parent)

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 176, 96)
	light.Brightness = 2.4
	light.Range = 34
	light.Parent = flame

	local fire = Instance.new("Fire")
	fire.Heat = 4
	fire.Size = 4
	fire.Color = Color3.fromRGB(255, 180, 90)
	fire.SecondaryColor = Color3.fromRGB(190, 90, 30)
	fire.Parent = flame
end

local function BuildTavern(origin)
	local folder = Instance.new("Folder")
	folder.Name = ARENA_FOLDER_NAME
	folder.Parent = Workspace

	local minV, maxV = HexGrid.GetBoardBounds(origin)
	local floorY = origin.Y - 0.5 -- topo do piso encosta na base dos hexágonos

	local minX = minV.X - TAVERN_MARGIN_LEFT
	local maxX = maxV.X + TAVERN_MARGIN_RIGHT
	local minZ = minV.Z - TAVERN_MARGIN_BACK
	local maxZ = maxV.Z + TAVERN_MARGIN_FRONT

	local width = maxX - minX
	local depth = maxZ - minZ
	local centerX = (minX + maxX) / 2
	local centerZ = (minZ + maxZ) / 2

	MakePart({
		Name = "Floor",
		Size = Vector3.new(width, 2, depth),
		CFrame = CFrame.new(centerX, floorY - 1, centerZ),
		Color = WOOD_FLOOR,
		Material = Enum.Material.WoodPlanks,
		CanCollide = true,
	}, folder)

	-- três paredes: fundo (-Z) e as duas laterais. A frente fica aberta.
	local wallY = floorY + TAVERN_WALL_HEIGHT / 2
	local walls = {
		{ size = Vector3.new(width, TAVERN_WALL_HEIGHT, TAVERN_WALL_THICKNESS), position = Vector3.new(centerX, wallY, minZ) },
		{ size = Vector3.new(TAVERN_WALL_THICKNESS, TAVERN_WALL_HEIGHT, depth), position = Vector3.new(minX, wallY, centerZ) },
		{ size = Vector3.new(TAVERN_WALL_THICKNESS, TAVERN_WALL_HEIGHT, depth), position = Vector3.new(maxX, wallY, centerZ) },
	}

	for index, wall in ipairs(walls) do
		MakePart({
			Name = "Wall" .. index,
			Size = wall.size,
			CFrame = CFrame.new(wall.position),
			Color = WOOD_DARK,
			Material = Enum.Material.WoodPlanks,
		}, folder)

		-- rodapé de pedra, quebra a parede lisa
		MakePart({
			Name = "Baseboard" .. index,
			Size = wall.size * Vector3.new(1, 0, 1) + Vector3.new(1, 7, 1),
			CFrame = CFrame.new(wall.position * Vector3.new(1, 0, 1) + Vector3.new(0, floorY + 3.5, 0)),
			Color = STONE_GREY,
			Material = Enum.Material.Slate,
		}, folder)
	end

	-- onde os dois competidores ficam de pé: nada de tralha em cima deles
	local reserved = {}
	for slot = 1, 2 do
		local stand = HexGrid.GetStandPosition(slot, floorY, origin)
		table.insert(reserved, Vector2.new(stand.X, stand.Z))
	end

	local function isBlocked(x, z)
		for _, point in ipairs(reserved) do
			if (Vector2.new(x, z) - point).Magnitude < 12 then return true end
		end
		-- nem sobre o tabuleiro
		return x > minV.X - 4 and x < maxV.X + 4
			and z > minV.Z - 4 and z < maxV.Z + 4
	end

	local spots = {}
	for x = minX + 8, maxX - 8, 13 do
		table.insert(spots, Vector2.new(x, minZ + 8))
	end
	for z = minZ + 20, maxZ - 10, 15 do
		table.insert(spots, Vector2.new(maxX - 8, z))
		table.insert(spots, Vector2.new(minX + 8, z))
	end

	for index, spot in ipairs(spots) do
		if not isBlocked(spot.X, spot.Y) then
			local position = Vector3.new(spot.X, floorY, spot.Y)
			if index % 3 == 0 then
				BuildTable(folder, position)
			else
				BuildBarrel(folder, position)
			end
		end
	end

	-- tochas na parede do fundo, que é a que aparece atrás do tabuleiro
	for i = 1, 4 do
		local x = minX + width * (i / 5)
		BuildTorch(folder, Vector3.new(x, floorY + 14, minZ + 1.5), Vector3.new(0, 0, 1))
	end

	return folder
end

-- Garante que o cenário existe, sem recriar o que já estiver lá. Pode ser
-- chamado no Studio em modo Edit pra materializar a taverna e personalizar
-- à mão — a partida reaproveita o que estiver salvo no place.
--
-- As arenas ficam montadas mesmo sem partida rodando: são cenário, custam nada
-- parado, e evitam o custo de reconstruir a cada início.
function BoardSpawner.EnsureArena(slot)
	slot = slot or 1

	HexGrid.SetHexSize(HEX_RADIUS)
	HexGrid.Generate()

	local name = ArenaFolderName(slot)
	local existing = Workspace:FindFirstChild(name)
	if existing then return existing end

	if slot <= 1 then
		return BuildTavern(GameConfig.ArenaOrigin(1))
	end

	-- clona a arena original em vez de reconstruir: o layout tem que ser
	-- idêntico, inclusive o que foi editado à mão no Studio
	local source = BoardSpawner.EnsureArena(1)
	local delta = GameConfig.ArenaOrigin(slot) - GameConfig.ArenaOrigin(1)

	local clone = source:Clone()
	clone.Name = name
	for _, descendant in ipairs(clone:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.CFrame = descendant.CFrame + delta
		end
	end
	clone.Parent = Workspace

	return clone
end

-- Bonequin do bot no slot 2, ao lado do jogador. Em PvP o slot 2 é o outro
-- jogador de verdade, então o bonequin nem é criado.
local function SpawnBotDummy(boardFolder, origin)
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
	local floorY = origin.Y - 0.5 -- mesmo piso que o BuildTavern usa
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

-- Monta o tabuleiro do slot pedido. withBotDummy = false nas partidas PvP, onde
-- o slot 2 é um jogador de verdade. Devolve o folder pra partida guardar — o
-- cliente recebe essa referência no snapshot e nunca procura "o Board" pelo
-- nome, que com várias partidas seria ambíguo.
function BoardSpawner.SpawnBoard(slot, withBotDummy)
	slot = slot or 1

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

	local allHexes = HexGrid.GetAllHexes()
	for _, hex in ipairs(allHexes) do
		local worldPos = HexGrid.GetWorldPosition(hex.id, origin)
		local color = (hex.col % 2 == 0) and COLOR_A or COLOR_B
		CreateHexTile(template, worldPos, color, hex.id).Parent = boardFolder
	end

	BoardSpawner.EnsureArena(slot)
	if withBotDummy then
		SpawnBotDummy(boardFolder, origin)
	end

	return boardFolder
end

return BoardSpawner
