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
-- As alturas por tema (20 a 30) foram escolhidas quando a câmera chegava bem
-- menos perto do limite: no zoom aberto o topo delas caía dentro do quadro e
-- aparecia céu (ou vazio) por cima. Com a câmera a ~78 de altura e as paredes a
-- ~93 de distância, 48 põe o topo delas ACIMA da borda superior da tela — o
-- tema continua mandando na cor e no material, só não pode mais ser baixo
-- demais pra fechar a caixa.
local MIN_BACKDROP_HEIGHT = 48

local function SeedOf(text)
	local seed = 0
	for index = 1, #text do
		seed = (seed * 31 + text:byte(index)) % 2147483647
	end
	return seed
end

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

local function StandingCylinder(props, parent)
	props.Shape = Enum.PartType.Cylinder
	props.CFrame = props.CFrame * CFrame.Angles(0, 0, math.rad(90))
	return MakePart(props, parent)
end

local function Jitter(rng, amount)
	return (rng:NextNumber() * 2 - 1) * amount
end

local function BuildRock(folder, spec, position, rng)
	local size = 3 + rng:NextNumber() * 4
	MakePart({
		Name = "Rock",
		Size = Vector3.new(size, size * (0.6 + rng:NextNumber() * 0.5), size * (0.8 + rng:NextNumber() * 0.4)),
		CFrame = CFrame.new(position + Vector3.new(0, size * 0.25, 0))
			* CFrame.Angles(Jitter(rng, 0.3), rng:NextNumber() * 6.28, Jitter(rng, 0.3)),
		Color = spec.color,
		Material = spec.material,
	}, folder)
end

local function BuildTree(folder, spec, position, rng)
	local height = 12 + rng:NextNumber() * 8

	StandingCylinder({
		Name = "TreeTrunk",
		Size = Vector3.new(height, 2.6, 2.6),
		CFrame = CFrame.new(position + Vector3.new(0, height / 2, 0)),
		Color = spec.trunk,
		Material = Enum.Material.Wood,
	}, folder)

	for index = 1, 2 do
		local blob = 9 - index * 2 + rng:NextNumber() * 3
		MakePart({
			Name = "TreeCrown",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(blob, blob * 0.8, blob),
			CFrame = CFrame.new(position + Vector3.new(Jitter(rng, 2), height - 1 + index * 3, Jitter(rng, 2))),
			Color = spec.leaf,
			Material = spec.material,
		}, folder)
	end
end

local function BuildDeadTree(folder, spec, position, rng)
	local height = 10 + rng:NextNumber() * 9

	StandingCylinder({
		Name = "DeadTrunk",
		Size = Vector3.new(height, 2, 2),
		CFrame = CFrame.new(position + Vector3.new(0, height / 2, 0))
			* CFrame.Angles(Jitter(rng, 0.12), 0, Jitter(rng, 0.12)),
		Color = spec.trunk,
		Material = spec.material,
	}, folder)

	for index = 1, 3 do
		local length = 4 + rng:NextNumber() * 4
		MakePart({
			Name = "DeadBranch",
			Size = Vector3.new(length, 0.9, 0.9),
			CFrame = CFrame.new(position + Vector3.new(0, height * (0.5 + index * 0.14), 0))
				* CFrame.Angles(0, rng:NextNumber() * 6.28, math.rad(20 + rng:NextNumber() * 35))
				* CFrame.new(length / 2, 0, 0),
			Color = spec.trunk,
			Material = spec.material,
		}, folder)
	end
end

local function BuildBush(folder, spec, position, rng)
	for index = 1, 3 do
		local blob = 3 + rng:NextNumber() * 3
		MakePart({
			Name = "Bush",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(blob, blob * 0.7, blob),
			CFrame = CFrame.new(position + Vector3.new(Jitter(rng, 2.5), blob * 0.3, Jitter(rng, 2.5))),
			Color = spec.color,
			Material = spec.material,
		}, folder)
	end
end

local function BuildCrystal(folder, spec, position, rng)
	local height = 7 + rng:NextNumber() * 9
	local width = 2.4 + rng:NextNumber() * 2

	for index = 1, 3 do
		local shard = height * (1 - (index - 1) * 0.28)
		MakePart({
			Name = "IceShard",
			Size = Vector3.new(width * (1 - (index - 1) * 0.2), shard, width * (1 - (index - 1) * 0.2)),
			CFrame = CFrame.new(position + Vector3.new(Jitter(rng, 3), shard / 2 - 1, Jitter(rng, 3)))
				* CFrame.Angles(math.rad(Jitter(rng, 14)), rng:NextNumber() * 6.28, math.rad(Jitter(rng, 14))),
			Color = spec.color,
			Material = spec.material,
			Transparency = spec.transparency or 0.2,
			Reflectance = 0.12,
		}, folder)
	end
end

local function BuildDrift(folder, spec, position, rng)
	local width = 7 + rng:NextNumber() * 7
	MakePart({
		Name = "SnowDrift",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(width, width * 0.35, width * (0.7 + rng:NextNumber() * 0.5)),
		CFrame = CFrame.new(position + Vector3.new(0, width * 0.08, 0))
			* CFrame.Angles(0, rng:NextNumber() * 6.28, 0),
		Color = spec.color,
		Material = spec.material,
	}, folder)
end

local function BuildPillar(folder, spec, position, rng)
	local height = 8 + rng:NextNumber() * 12

	StandingCylinder({
		Name = "Pillar",
		Size = Vector3.new(height, 4.2, 4.2),
		CFrame = CFrame.new(position + Vector3.new(0, height / 2, 0)),
		Color = spec.color,
		Material = spec.material,
	}, folder)

	MakePart({
		Name = "PillarBase",
		Size = Vector3.new(6, 1.2, 6),
		CFrame = CFrame.new(position + Vector3.new(0, 0.6, 0))
			* CFrame.Angles(0, rng:NextNumber() * 6.28, 0),
		Color = spec.color,
		Material = spec.material,
	}, folder)

	if rng:NextNumber() < 0.4 then
		local chunk = 4 + rng:NextNumber() * 5
		StandingCylinder({
			Name = "PillarChunk",
			Size = Vector3.new(chunk, 4, 4),
			CFrame = CFrame.new(position + Vector3.new(Jitter(rng, 7), 2, Jitter(rng, 7)))
				* CFrame.Angles(0, rng:NextNumber() * 6.28, math.rad(90)),
			Color = spec.color,
			Material = spec.material,
		}, folder)
	end
end

local function BuildBrazier(folder, spec, position, rng)
	local height = 5 + rng:NextNumber() * 3

	StandingCylinder({
		Name = "BrazierStem",
		Size = Vector3.new(height, 1.4, 1.4),
		CFrame = CFrame.new(position + Vector3.new(0, height / 2, 0)),
		Color = Color3.fromRGB(52, 46, 42),
		Material = spec.material,
	}, folder)

	StandingCylinder({
		Name = "BrazierBowl",
		Size = Vector3.new(1.6, 5, 5),
		CFrame = CFrame.new(position + Vector3.new(0, height + 0.6, 0)),
		Color = Color3.fromRGB(64, 56, 50),
		Material = spec.material,
	}, folder)

	local ember = MakePart({
		Name = "BrazierEmber",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(3, 2.2, 3),
		CFrame = CFrame.new(position + Vector3.new(0, height + 1.6, 0)),
		Color = spec.color,
		Material = Enum.Material.Neon,
	}, folder)

	local light = Instance.new("PointLight")
	light.Color = spec.color
	light.Brightness = 2
	light.Range = 30
	light.Parent = ember

	local fire = Instance.new("Fire")
	fire.Heat = 3
	fire.Size = 4
	fire.Color = spec.color
	fire.SecondaryColor = Color3.fromRGB(180, 74, 26)
	fire.Parent = ember
end

local function BuildLava(folder, spec, position, rng)
	local width = 9 + rng:NextNumber() * 10

	local pool = MakePart({
		Name = "LavaPool",
		Size = Vector3.new(width, 0.6, width * (0.5 + rng:NextNumber() * 0.6)),
		CFrame = CFrame.new(position + Vector3.new(0, 0.4, 0)) * CFrame.Angles(0, rng:NextNumber() * 6.28, 0),
		Color = spec.color,
		Material = spec.material,
	}, folder)

	local light = Instance.new("PointLight")
	light.Color = spec.color
	light.Brightness = 1.6
	light.Range = 26
	light.Parent = pool
end

local BUILDERS = {
	rock = BuildRock,
	tree = BuildTree,
	deadTree = BuildDeadTree,
	bush = BuildBush,
	crystal = BuildCrystal,
	drift = BuildDrift,
	pillar = BuildPillar,
	brazier = BuildBrazier,
	lava = BuildLava,
}

local function BuildBackdrop(folder, theme, bounds, rng)
	local spec = theme.backdrop
	if not spec then return end

	local minX, maxX, minZ, maxZ, floorY = bounds.minX, bounds.maxX, bounds.minZ, bounds.maxZ, bounds.floorY
	local height = math.max(spec.height, MIN_BACKDROP_HEIGHT)

	-- Três bordas, nunca a de +X: aquela é a frente aberta do diorama, e uma
	-- parede ali ficaria entre a câmera e o jogo.
	--
	-- As laterais vão até maxX AGORA. Antes paravam em `boardMax.X - 6` porque,
	-- com MARGIN_SIDE em 30, elas passavam perto demais da câmera e subiam no
	-- enquadramento por cima das casas. Com a margem lateral em 62 elas ficam a
	-- ~93 studs do centro — fora do jogo, na borda da tela — e o que o corte
	-- deixava pra trás era o vão preto nos cantos da frente.
	local edges = {
		{ from = Vector3.new(minX, floorY, minZ), to = Vector3.new(minX, floorY, maxZ) },
		{ from = Vector3.new(minX, floorY, minZ), to = Vector3.new(maxX, floorY, minZ) },
		{ from = Vector3.new(minX, floorY, maxZ), to = Vector3.new(maxX, floorY, maxZ) },
	}

	if spec.style == "wall" then
		for index, edge in ipairs(edges) do
			local span = (edge.to - edge.from)
			local length = span.Magnitude
			local center = (edge.from + edge.to) / 2

			MakePart({
				Name = "Backdrop" .. index,
				Size = Vector3.new(math.max(math.abs(span.X), 2), height, math.max(math.abs(span.Z), 2)),
				CFrame = CFrame.new(center + Vector3.new(0, height / 2, 0)),
				Color = spec.color,
				Material = spec.material,
			}, folder)

			if length > 0 then
				MakePart({
					Name = "BackdropTrim" .. index,
					Size = Vector3.new(math.max(math.abs(span.X), 3), 2, math.max(math.abs(span.Z), 3)),
					CFrame = CFrame.new(center + Vector3.new(0, height, 0)),
					Color = theme.trim.color,
					Material = theme.trim.material,
				}, folder)
			end
		end
		return
	end

	for index, edge in ipairs(edges) do
		local span = edge.to - edge.from
		local length = span.Magnitude
		local steps = math.max(3, math.floor(length / 11))
		local direction = span.Unit

		for step = 0, steps do
			local at = edge.from + direction * (length * step / steps)
			-- varia em torno da altura MÍNIMA, não da do tema: o penhasco continua
			-- irregular (é o charme dele), mas nenhum bloco pode ficar baixo a
			-- ponto de abrir buraco na parede pro vazio.
			local blockHeight = height * (0.85 + rng:NextNumber() * 0.5)
			local width = 9 + rng:NextNumber() * 8

			MakePart({
				Name = "Cliff" .. index .. "_" .. step,
				Size = Vector3.new(width, blockHeight, width * (0.7 + rng:NextNumber() * 0.6)),
				CFrame = CFrame.new(at + Vector3.new(Jitter(rng, 3), blockHeight / 2 - 2, Jitter(rng, 3)))
					* CFrame.Angles(math.rad(Jitter(rng, 5)), rng:NextNumber() * 6.28, math.rad(Jitter(rng, 5))),
				Color = spec.color,
				Material = spec.material,
			}, folder)
		end
	end
end

local function BuildParticles(folder, theme, bounds)
	local spec = theme.particles
	if not spec then return end

	local drift = spec.drift or Vector3.new(0, 1, 0)
	local width = bounds.maxX - bounds.minX
	local depth = bounds.maxZ - bounds.minZ
	local high = drift.Y < 0

	local emitterPart = MakePart({
		Name = "Ambience",
		Size = Vector3.new(width, 2, depth),
		CFrame = CFrame.new(bounds.boardCenterX, bounds.floorY + (high and 46 or 6), bounds.boardCenterZ),
		Transparency = 1,
	}, folder)

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Emitter"
	emitter.Texture = spec.texture
	emitter.Color = ColorSequence.new(spec.color)
	emitter.Rate = spec.rate
	emitter.Lifetime = NumberRange.new(spec.lifetime * 0.7, spec.lifetime)
	emitter.Speed = NumberRange.new(spec.speed * 0.5, spec.speed)
	emitter.Size = NumberSequence.new(spec.size)
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.2, spec.transparency),
		NumberSequenceKeypoint.new(0.8, spec.transparency),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Acceleration = drift
	emitter.SpreadAngle = Vector2.new(40, 40)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-30, 30)
	emitter.LightEmission = 0.35
	emitter.EmissionDirection = high and Enum.NormalId.Bottom or Enum.NormalId.Top
	emitter.Parent = emitterPart
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

local function ScatterProps(folder, theme, bounds, rng)
	local reserved = {}
	for slot = 1, 2 do
		local stand = HexGrid.GetStandPosition(slot, bounds.floorY, bounds.origin)
		table.insert(reserved, Vector2.new(stand.X, stand.Z))
	end

	local function isBlocked(x, z)
		for _, point in ipairs(reserved) do
			if (Vector2.new(x, z) - point).Magnitude < 20 then return true end
		end

		-- Nada entre a câmera e o tabuleiro: ela olha de +X, então o que nascer
		-- passando dessa borda aparece POR CIMA das casas — objeto tapando fileira
		-- custa a partida, não só a beleza.
		if x > bounds.boardMax.X then return true end

		return x > bounds.boardMin.X - 6 and x < bounds.boardMax.X + 6
			and z > bounds.boardMin.Z - 6 and z < bounds.boardMax.Z + 6
	end

	local spots = {}
	for z = bounds.minZ + 8, bounds.maxZ - 8, 10 do
		table.insert(spots, Vector2.new(bounds.minX + 9, z))
	end
	-- Só a METADE DE TRÁS das laterais: um prop na metade perto da câmera fica
	-- baixo na tela e sobe por cima da quina do tabuleiro.
	for x = bounds.minX + 13, bounds.boardCenterX, 8 do
		table.insert(spots, Vector2.new(x, bounds.minZ + 8))
		table.insert(spots, Vector2.new(x, bounds.maxZ - 8))
	end

	for index = #spots, 2, -1 do
		local swap = rng:NextInteger(1, index)
		spots[index], spots[swap] = spots[swap], spots[index]
	end

	local cursor = 1
	for _, spec in ipairs(theme.props or {}) do
		local builder = BUILDERS[spec.kind]
		local placed = 0

		while builder and placed < spec.count and cursor <= #spots do
			local spot = spots[cursor]
			cursor += 1

			if not isBlocked(spot.X, spot.Y) then
				builder(folder, spec, Vector3.new(spot.X + Jitter(rng, 2), bounds.floorY, spot.Y + Jitter(rng, 2)), rng)
				placed += 1
			end
		end
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

	-- Luz e partículas seguem o TABULEIRO, não o meio do piso: com a folga da
	-- câmera o piso é assimétrico, e centrar nele puxaria o poço de luz pra fora
	-- do jogo.
	bounds.boardCenterX = (boardMin.X + boardMax.X) / 2
	bounds.boardCenterZ = (boardMin.Z + boardMax.Z) / 2

	local width = bounds.maxX - bounds.minX
	local depth = bounds.maxZ - bounds.minZ
	local rng = Random.new(SeedOf(theme.id))

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
		CFrame = CFrame.new(bounds.centerX, floorY - FLOOR_THICKNESS / 2 - TRIM_DROP / 2, bounds.centerZ),
		Color = theme.trim.color,
		Material = theme.trim.material,
	}, folder)

	BuildBackdrop(folder, theme, bounds, rng)
	ScatterProps(folder, theme, bounds, rng)
	BuildParticles(folder, theme, bounds)
	BuildLights(folder, theme, bounds)

	folder.Parent = Workspace
	return folder
end

function ArenaBuilder.CloneMaster(master, theme, origin, folderName)
	local reference = master:FindFirstChild("Floor", true)
	if not reference or not reference:IsA("BasePart") then
		warn(("ArenaBuilder: %s não tem uma peça 'Floor' — não dá pra alinhar o clone."):format(master.Name))
		return nil
	end

	local center = HexGrid.GetBoardCenter(origin)
	local delta = Vector3.new(
		center.X - reference.Position.X,
		(origin.Y - 0.5) - (reference.Position.Y + reference.Size.Y / 2),
		center.Z - reference.Position.Z
	)

	local folder
	if master:IsA("Folder") then
		folder = master:Clone()
	else
		folder = Instance.new("Folder")
		local copy = master:Clone()
		copy.Parent = folder
	end

	folder.Name = folderName
	folder:SetAttribute("Theme", theme.id)

	for _, descendant in ipairs(folder:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.CFrame = descendant.CFrame + delta
			descendant.CastShadow = false
		end
	end

	folder.Parent = Workspace
	return folder
end

return ArenaBuilder
