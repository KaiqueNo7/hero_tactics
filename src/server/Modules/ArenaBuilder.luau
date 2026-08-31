local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local HexGrid = require(ReplicatedStorage.Modules.HexGrid)

local ArenaBuilder = {}

-- Margens medidas EM RELAÇÃO À CÂMERA, não aos eixos do mundo: ela orbita em
-- azimute 91 graus (ver CameraController), ou seja, olha o tabuleiro de +X pra
-- -X. Então +X é a frente aberta (precisa de chão sobrando pra câmera não ver o
-- vazio embaixo dela), -X é o fundo que aparece no topo da tela, e as duas
-- bordas de Z são as laterais — que é onde os dois competidores ficam de pé.
-- Estas margens têm que CONTER A CÂMERA, não só emoldurar o tabuleiro. Ela
-- orbita a boardCenter num raio que chega a DEFAULT_DISTANCE * ZOOM_MAX_FACTOR
-- (ver CameraController): no azimute 91° com elevação 44°, o afastamento em X é
-- 0.72 * raio. Com o zoom máximo atual isso põe a câmera ~57 studs além da
-- borda do tabuleiro — se MARGIN_CAMERA for menor que isso, no zoom aberto a
-- câmera fica FORA do diorama e enxerga o vazio por baixo e pelos lados.
-- Era exatamente esse o "vão preto": 60 aqui contra uma câmera que ia a 73.
local MARGIN_CAMERA = 80
local MARGIN_BACK = 48
local MARGIN_SIDE = 62

-- Piso 48 x 62 (tabuleiro) + margens = ~176 x ~186. Tem que caber dentro de
-- GameConfig.ARENA_SPACING, senão o piso de uma arena invade a vizinha.
local FLOOR_THICKNESS = 2
local TRIM_OUTSET = 6
local TRIM_DROP = 3

-- Altura MÍNIMA de qualquer parede/penhasco, independente do que o tema pede.
local function MakePart(props, parent)
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false

	for key, value in pairs(props) do
		part[key] = value
	end

	part.Parent = parent
	return part
end

local function BuildLights(folder, theme, bounds)
	for index, spec in ipairs(theme.lights or {}) do
		local offset = spec.offset or Vector3.new()
		local anchor = MakePart({
			Name = "ArenaLight" .. index,
			Size = Vector3.new(0.4, 0.4, 0.4),
			CFrame = CFrame.new(bounds.boardCenterX + offset.X, bounds.floorY + spec.height, bounds.boardCenterZ + offset.Z),
			Transparency = 1,
		}, folder)

		local light = Instance.new(spec.class)
		light.Color = spec.color
		light.Brightness = spec.brightness
		light.Range = spec.range
		light.Parent = anchor
	end
end

function ArenaBuilder.Build(theme, origin, folderName)
	local folder = Instance.new("Folder")
	folder.Name = folderName
	folder:SetAttribute("Theme", theme.id)

	local boardMin, boardMax = HexGrid.GetBoardBounds(origin)
	local floorY = origin.Y - 0.5

	local bounds = {
		origin = origin,
		boardMin = boardMin,
		boardMax = boardMax,
		floorY = floorY,
		minX = boardMin.X - MARGIN_BACK,
		maxX = boardMax.X + MARGIN_CAMERA,
		minZ = boardMin.Z - MARGIN_SIDE,
		maxZ = boardMax.Z + MARGIN_SIDE,
	}
	bounds.centerX = (bounds.minX + bounds.maxX) / 2
	bounds.centerZ = (bounds.minZ + bounds.maxZ) / 2

	-- A luz segue o TABULEIRO, não o meio do piso: com a folga da câmera o piso
	-- é assimétrico, e centrar nele puxaria o poço de luz pra fora do jogo.
	bounds.boardCenterX = (boardMin.X + boardMax.X) / 2
	bounds.boardCenterZ = (boardMin.Z + boardMax.Z) / 2

	local width = bounds.maxX - bounds.minX
	local depth = bounds.maxZ - bounds.minZ

	MakePart({
		Name = "Floor",
		Size = Vector3.new(width, FLOOR_THICKNESS, depth),
		CFrame = CFrame.new(bounds.centerX, floorY - FLOOR_THICKNESS / 2, bounds.centerZ),
		Color = theme.ground.color,
		Material = theme.ground.material,
		CanCollide = true,
	}, folder)

	MakePart({
		Name = "FloorTrim",
		Size = Vector3.new(width + TRIM_OUTSET, FLOOR_THICKNESS + TRIM_DROP, depth + TRIM_OUTSET),
		CFrame = CFrame.new(bounds.centerX, floorY - FLOOR_THICKNESS - (FLOOR_THICKNESS + TRIM_DROP) / 2, bounds.centerZ),
		Color = theme.trim.color,
		Material = theme.trim.material,
	}, folder)

	BuildLights(folder, theme, bounds)

	folder.Parent = Workspace
	return folder
end

function ArenaBuilder.CloneMaster(master, theme, origin, folderName)
	local center = HexGrid.GetBoardCenter(origin)
	local floorY = origin.Y - 0.5

	local folder = master:Clone()
	folder.Name = folderName
	folder:SetAttribute("Theme", theme.id)
	folder:SetAttribute("MasterName", master.Name)

	local reference = folder:FindFirstChild("Floor", true)
	local delta

	if reference and reference:IsA("BasePart") then
		delta = Vector3.new(
			center.X - reference.Position.X,
			floorY - (reference.Position.Y + reference.Size.Y / 2),
			center.Z - reference.Position.Z
		)
	elseif folder:IsA("PVInstance") then
		local pivot = folder:GetPivot()
		delta = Vector3.new(center.X - pivot.X, floorY - pivot.Y, center.Z - pivot.Z)
		warn(("ArenaBuilder: %s nao tem peca 'Floor' — alinhado pelo pivot do Model."):format(master.Name))
	else
		warn(("ArenaBuilder: %s nao tem peca 'Floor' e nao e Model — nao da pra alinhar."):format(master.Name))
		folder:Destroy()
		return nil
	end

	if folder:IsA("PVInstance") then
		folder:PivotTo(folder:GetPivot() + delta)
	else
		for _, descendant in ipairs(folder:GetDescendants()) do
			if descendant:IsA("PVInstance") and not descendant:FindFirstAncestorWhichIsA("Model") then
				descendant:PivotTo(descendant:GetPivot() + delta)
			end
		end
	end

	BuildLights(folder, theme, {
		boardCenterX = center.X,
		boardCenterZ = center.Z,
		floorY = floorY,
	})

	folder.Parent = Workspace
	return folder
end

return ArenaBuilder
