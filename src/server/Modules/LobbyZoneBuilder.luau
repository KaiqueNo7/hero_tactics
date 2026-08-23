--[[
	LobbyZoneBuilder.lua
	ModuleScript — ServerScriptService/Modules/LobbyZoneBuilder

	Levanta a trilha desenhada em ReplicatedStorage.Modules.LobbyZones: uma
	ilhota por grupo da campanha, as pontes entre elas e a vegetação de cada
	bioma.

	IDEMPOTENTE, e isso não é detalhe. Tudo que ele cria mora dentro de uma pasta
	só (Workspace.LobbyTrail) e é reconstruído do zero a cada chamada. Rodar duas
	vezes dá o mesmo lobby, não dois lobbies empilhados — que foi exatamente o
	risco de construir cenário por script em cima de um place que já existe.

	Nada FORA dessa pasta é tocado, com uma exceção declarada: os quadrados de
	confronto, que são reposicionados nos encaixes da zona do grupo deles (a
	política e a saída de emergência estão no cabeçalho do LobbyZones).

	Igual ao LightingSetup e ao LeaderboardBoardView, dá pra chamar em modo Edit
	pra ver o resultado sem dar play:

		require(game.ServerScriptService.Modules.LobbyZoneBuilder).Build()
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LobbyZones = require(ReplicatedStorage.Modules.LobbyZones)
local Campaign = require(ReplicatedStorage.Modules.Campaign)

local LobbyZoneBuilder = {}

local FOLDER_NAME = "LobbyTrail"

-- ===== PEÇAS =====
local function NewPart(name, size, cframe, color, material, parent)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.CanCollide = true
	-- O lustre ensinou a lição: peça decorativa que projeta sombra come
	-- legibilidade. Aqui quem faz o clima é a Atmosphere da zona, não a sombra
	-- de cada arbusto — e são dezenas deles.
	part.CastShadow = false
	part.Parent = parent
	return part
end

-- Sorteio ESTÁVEL por zona: a mesma zona sai igual em todo servidor. Com
-- math.random puro, cada servidor desenhava uma floresta diferente e dois
-- jogadores no mesmo lugar viam árvores em posições diferentes — o cenário é
-- replicado, então ele precisa ser o mesmo objeto pra todo mundo, e reconstruir
-- igual é o que garante isso depois de um restart.
local function SeededRandom(zone)
	local seed = 0
	for index = 1, #zone.id do
		seed += string.byte(zone.id, index) * index
	end
	return Random.new(seed)
end

-- ===== VEGETAÇÃO =====
-- Um construtor só, quatro biomas. As diferenças entre um pinheiro, um tronco
-- morto, um pico de gelo e uma rocha em brasa são altura, número de camadas e
-- cor — não quatro funções. `kind` só escolhe o formato das camadas.
local function BuildProp(zone, parent, position, rng)
	local props = zone.props
	local kind = props.kind

	local height = rng:NextNumber(7, 13)
	local trunkHeight = kind == "shard" and height * 0.2 or height * 0.45
	local trunkWidth = rng:NextNumber(1.4, 2.4)

	local trunk = NewPart("Trunk",
		Vector3.new(trunkWidth, trunkHeight, trunkWidth),
		CFrame.new(position + Vector3.new(0, trunkHeight / 2, 0)),
		props.trunk, Enum.Material.Wood, parent)

	if kind == "dead" then
		-- galho seco: o tronco inclina e ganha dois braços, sem copa nenhuma.
		-- É a ausência de folha que faz o bosque parecer morto.
		trunk.Material = Enum.Material.Wood
		trunk.CFrame = CFrame.new(position + Vector3.new(0, trunkHeight / 2, 0))
			* CFrame.Angles(math.rad(rng:NextNumber(-14, 14)), 0, math.rad(rng:NextNumber(-14, 14)))

		for _ = 1, 2 do
			local armLength = rng:NextNumber(3, 5.5)
			NewPart("Branch",
				Vector3.new(0.8, armLength, 0.8),
				trunk.CFrame
					* CFrame.new(0, trunkHeight * rng:NextNumber(0.1, 0.4), 0)
					* CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), math.rad(rng:NextNumber(45, 75)))
					* CFrame.new(0, armLength / 2, 0),
				props.trunk, Enum.Material.Wood, parent)
		end
		return
	end

	if kind == "ember" then
		-- pedra com a brasa por dentro: o Neon é o que "acende" sem custar luz
		trunk.Material = Enum.Material.Basalt
		trunk.Size = Vector3.new(trunkWidth * 2.2, trunkHeight * 0.7, trunkWidth * 2.2)
		trunk.CFrame = CFrame.new(position + Vector3.new(0, trunkHeight * 0.35, 0))
			* CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0)

		local glow = NewPart("Ember",
			Vector3.new(trunkWidth * 0.7, trunkHeight * 0.5, trunkWidth * 0.7),
			trunk.CFrame * CFrame.new(0, trunkHeight * 0.3, 0),
			props.foliage[rng:NextInteger(1, #props.foliage)], Enum.Material.Neon, parent)
		glow.CanCollide = false
		return
	end

	-- conifer e shard: camadas empilhadas que afinam pra cima. O pinheiro tem
	-- cones largos e baixos; o pico de gelo, poucos e altos.
	local layers = kind == "shard" and 2 or 3
	local layerHeight = (height - trunkHeight) / layers
	local width = kind == "shard" and trunkWidth * 2.4 or trunkWidth * 4

	for layer = 1, layers do
		local shrink = 1 - (layer - 1) / (layers + 0.6)
		local y = trunkHeight + layerHeight * (layer - 0.5)

		local piece = NewPart("Canopy",
			Vector3.new(width * shrink, layerHeight * 1.15, width * shrink),
			CFrame.new(position + Vector3.new(0, y, 0))
				* CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0),
			props.foliage[rng:NextInteger(1, #props.foliage)],
			kind == "shard" and Enum.Material.Ice or Enum.Material.Grass,
			parent)

		if kind == "shard" then
			piece.Transparency = 0.25
			piece.Reflectance = 0.2
		end
	end
end

-- ===== ILHA =====
-- A borda é uma peça a mais, mais larga e mais baixa: dá o "penhasco" de graça,
-- no mesmo estilo achatado do lobby, sem mesh nova.
local function BuildIsland(zone, parent)
	local span = LobbyZones.ISLAND_SPAN
	local thickness = LobbyZones.ISLAND_THICKNESS
	local center = Vector3.new(zone.center.X, LobbyZones.GROUND_Y, zone.center.Y)

	NewPart(zone.id .. "_Rim",
		Vector3.new(span + 8, thickness * 1.6, span + 8),
		CFrame.new(center - Vector3.new(0, thickness * 0.9, 0)),
		zone.rim, Enum.Material.Rock, parent)

	local floor = NewPart(zone.id .. "_Floor",
		Vector3.new(span, thickness, span),
		CFrame.new(center - Vector3.new(0, thickness / 2, 0)),
		zone.ground.color, zone.ground.material, parent)

	-- placa com o nome: é o que transforma "mais uma ilha" em "cheguei na
	-- Geleira". MaxDistance recortado na distância entre duas zonas — sem ele as
	-- quatro placas aparecem juntas e se sobrepõem numa sopa de letra, que foi
	-- exatamente o que a primeira montagem mostrou.
	local sign = Instance.new("BillboardGui")
	sign.Name = "ZoneSign"
	sign.Size = UDim2.new(0, 200, 0, 44)
	sign.StudsOffset = Vector3.new(0, 16, 0)
	sign.MaxDistance = 130
	sign.AlwaysOnTop = false
	sign.Parent = floor

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 1, 0)
	title.BackgroundTransparency = 1
	title.Text = zone.name:upper()
	title.TextColor3 = Color3.new(1, 1, 1)
	title.TextStrokeTransparency = 0.25
	title.TextScaled = true
	title.Font = Enum.Font.GothamBlack
	title.Parent = sign

	-- props espalhados pela BORDA, deixando o miolo livre pros quadrados: mata
	-- plantada no meio vira obstáculo entre o jogador e o confronto.
	local rng = SeededRandom(zone)
	local inner = span / 2 - 6

	for _ = 1, zone.props.count do
		local edge = rng:NextInteger(1, 4)
		local along = rng:NextNumber(-inner, inner)
		local depth = rng:NextNumber(inner * 0.6, inner)

		local offset
		if edge == 1 then offset = Vector2.new(along, -depth)
		elseif edge == 2 then offset = Vector2.new(along, depth)
		elseif edge == 3 then offset = Vector2.new(-depth, along)
		else offset = Vector2.new(depth, along) end

		BuildProp(zone, parent, Vector3.new(
			zone.center.X + offset.X,
			LobbyZones.GROUND_Y,
			zone.center.Y + offset.Y), rng)
	end
end

-- ===== PONTE =====
-- Ponto a ponto, com a prancha girada pra direção da travessia. Ser genérica é
-- o que permite reorganizar as zonas mexendo só nas coordenadas do LobbyZones:
-- ponte diagonal, mais curta ou mais longa sai da mesma função.
local function BuildBridge(fromCenter, toCenter, index, parent)
	local a = Vector3.new(fromCenter.X, LobbyZones.GROUND_Y, fromCenter.Y)
	local b = Vector3.new(toCenter.X, LobbyZones.GROUND_Y, toCenter.Y)

	local direction = (b - a)
	local distance = direction.Magnitude
	if distance < 1 then return end
	direction = direction.Unit

	-- recorta o que está DENTRO das ilhas: a ponte liga borda a borda, senão
	-- ela atravessa a ilha inteira por baixo do chão
	local half = LobbyZones.ISLAND_SPAN / 2
	local startInset = index == 1 and 0 or half -- o lobby não tem borda calculada
	local span = distance - startInset - half
	if span <= 2 then return end

	local start = a + direction * startInset
	local middle = start + direction * (span / 2)

	local plank = NewPart("Bridge_" .. index,
		Vector3.new(LobbyZones.BRIDGE_WIDTH, LobbyZones.BRIDGE_THICKNESS, span),
		CFrame.lookAt(middle - Vector3.new(0, LobbyZones.BRIDGE_THICKNESS / 2, 0),
			middle - Vector3.new(0, LobbyZones.BRIDGE_THICKNESS / 2, 0) + direction),
		Color3.fromRGB(120, 88, 56), Enum.Material.WoodPlanks, parent)

	-- Corrimão dos dois lados. Não é enfeite: sem ele a criança anda de lado e
	-- cai no vazio, e cair não devolve nada aqui — é só frustração.
	for _, side in ipairs({ -1, 1 }) do
		local rail = NewPart("Rail",
			Vector3.new(1, 3.5, span),
			plank.CFrame * CFrame.new(side * (LobbyZones.BRIDGE_WIDTH / 2 - 0.5), 2.5, 0),
			Color3.fromRGB(96, 70, 44), Enum.Material.WoodPlanks, parent)
		rail.CanCollide = true
	end
end

-- ===== A REDE =====
-- Entre as ilhas existe um buraco, e criança vai cair nele. Sem esta peça,
-- cair significa despencar até o fim do mundo e esperar o respawn — num jogo
-- pra criança isso é castigo por ter explorado. Encostou, volta pra entrada da
-- trilha e segue andando.
--
-- A água que ficava aqui saiu: o cenário do vão é de quem edita o place. Esta
-- peça é invisível e só existe pela regra, não pelo visual — ela não atrapalha
-- nada que for construído por cima. Pra desligar, é só não chamar
-- BuildFallNet no BuildTerrain.
local function TrailBounds(margin)
	local min, max = Vector2.new(1e9, 1e9), Vector2.new(-1e9, -1e9)
	local half = LobbyZones.ISLAND_SPAN / 2 + margin

	for _, point in ipairs(LobbyZones.PathPoints()) do
		min = Vector2.new(math.min(min.X, point.X - half), math.min(min.Y, point.Y - half))
		max = Vector2.new(math.max(max.X, point.X + half), math.max(max.Y, point.Y + half))
	end
	return min, max
end

local function BuildFallNet(folder)
	-- Margem larga: a rede precisa cobrir bem mais que as ilhas, senão quem
	-- pula com impulso passa POR FORA dela e cai assim mesmo.
	local min, max = TrailBounds(180)
	local span = max - min
	local center = (min + max) / 2

	local net = NewPart("FallCatcher",
		Vector3.new(span.X, 4, span.Y),
		CFrame.new(center.X, LobbyZones.GROUND_Y - 45, center.Y),
		Color3.fromRGB(0, 0, 0), Enum.Material.SmoothPlastic, folder)
	net.CanCollide = false
	net.Transparency = 1

	local exit = LobbyZones.LOBBY_EXIT
	local landing = CFrame.new(exit.X - 14, LobbyZones.GROUND_Y + 4, exit.Y)

	net.Touched:Connect(function(hit)
		local character = hit.Parent
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and humanoid and humanoid.Health > 0 then
			root.CFrame = landing
		end
	end)
end

-- ===== QUADRADOS DA CAMPANHA =====
-- Reposiciona cada pad no encaixe da zona do grupo dele. Ver o cabeçalho do
-- LobbyZones: quem manda na coordenada é a planta, não o Explorer — e
-- `KeepPosition` no pad é a saída pra travar um quadrado no lugar.
function LobbyZoneBuilder.PlacePads()
	local byGroup = {}
	for _, fight in ipairs(Campaign.FIGHTS) do
		byGroup[fight.group] = byGroup[fight.group] or {}
		table.insert(byGroup[fight.group], fight)
	end

	local moved, kept = 0, 0

	for group, fights in pairs(byGroup) do
		local zone = LobbyZones.ForGroup(group)
		if zone then
			local slots = LobbyZones.PadSlots(zone, #fights)

			for index, fight in ipairs(fights) do
				local pad = Workspace:FindFirstChild("FightPad_" .. fight.hero, true)
				if pad and pad:IsA("BasePart") then
					if pad:GetAttribute("KeepPosition") then
						kept += 1
					else
						-- CFrame e não Position: pad adotado do place pode vir
						-- torto, e um quadrado inclinado é uma rampa que joga o
						-- jogador pra fora da ilha
						pad.CFrame = CFrame.new(slots[index])
						pad:SetAttribute("TrailZone", zone.id)
						moved += 1
					end
				end
			end
		end
	end

	print(("LobbyZoneBuilder: %d quadrados posicionados na trilha (%d preservados por KeepPosition).")
		:format(moved, kept))
end

-- ===== ENTRADA =====
-- Terreno e quadrados são DUAS chamadas de propósito, e a ordem importa: quem
-- cria os pads que faltam é o GameStartTrigger, então ele levanta o terreno,
-- deixa os pads nascerem e só depois manda posicionar. Numa chamada só, o
-- PlacePads correria antes de o primeiro pad existir e não acharia nada.
function LobbyZoneBuilder.BuildTerrain()
	local existing = Workspace:FindFirstChild(FOLDER_NAME)
	if existing then existing:Destroy() end

	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = Workspace

	for _, zone in ipairs(LobbyZones.ZONES) do
		BuildIsland(zone, folder)
	end

	local points = LobbyZones.PathPoints()
	for index = 1, #points - 1 do
		BuildBridge(points[index], points[index + 1], index, folder)
	end

	BuildFallNet(folder)

	print(("LobbyZoneBuilder: %d zonas, %d pontes, %d peças.")
		:format(#LobbyZones.ZONES, #points - 1, #folder:GetDescendants()))
end

-- Atalho pro modo Edit, onde não existe GameStartTrigger rodando pra ordenar as
-- duas metades.
function LobbyZoneBuilder.Build()
	LobbyZoneBuilder.BuildTerrain()
	LobbyZoneBuilder.PlacePads()
end

return LobbyZoneBuilder
