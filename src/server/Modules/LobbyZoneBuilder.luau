--[[
	LobbyZoneBuilder.lua
	ModuleScript — ServerScriptService/Modules/LobbyZoneBuilder

	Levanta as ilhas desenhadas em ReplicatedStorage.Modules.LobbyZones: uma por
	grupo da campanha, em cruz em volta do lobby, cada uma com a ponte que a liga
	a ele.

	SÓ CHÃO, BORDA E PONTE. Ele já plantou árvore, pedra e brasa por código; saiu
	tudo. Cenário gerado por script destoa de qualquer coisa montada à mão, e o
	lobby é montado à mão — o construtor entrega a superfície nivelada, o encaixe
	dos quadrados e a rede anti-queda, e o Studio faz o resto por cima.

	O PLACE GANHA DELE. Achando Workspace.LobbyTrail já montado, ele ADOTA o que
	está lá e não constrói nada — nem ilha, nem ponte, nem reposiciona quadrado.
	Ele só levanta a trilha num place que ainda não tem uma.

	Isso não é preguiça, é o bug que ele causava: a trilha nasceu por código, foi
	alinhada à mão no Studio (ilhas giradas pra ficar de esquadro com as pontes,
	quadrados espalhados pela ilha) e o play seguinte desfazia tudo, em silêncio,
	de volta pros números da planta. Alinhar pelo Explorer é o fluxo normal deste
	projeto — o construtor entrega a primeira versão e sai da frente.

	Continua IDEMPOTENTE quando constrói: tudo mora numa pasta só e sai junto,
	então um rebuild dá o mesmo lobby, nunca dois empilhados.

	Pra jogar fora a montagem do place e voltar pra planta, é explícito:

		require(game.ServerScriptService.Modules.LobbyZoneBuilder).Build(true)

	Igual ao LightingSetup e ao LeaderboardBoardView, dá pra chamar em modo Edit
	pra ver o resultado sem dar play (aqui sem argumento não faz nada, porque a
	trilha já existe — use Build(true) pra reconstruir de verdade).
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LobbyZones = require(ReplicatedStorage.Modules.LobbyZones)
local Campaign = require(ReplicatedStorage.Modules.Campaign)

local LobbyZoneBuilder = {}

local FOLDER_NAME = "LobbyTrail"

-- Lembrado entre as duas metades da entrada: BuildTerrain e PlacePads são
-- chamadas separadas (ver ENTRADA), e quem decide se pode mexer nos quadrados é
-- o que aconteceu com o terreno lá atrás. Trilha adotada do place = a montagem à
-- mão manda em tudo, quadrado incluído.
local adopted = false

-- Zonas levantadas NESTA chamada. Numa trilha adotada, é o que separa "esta ilha
-- é sua, não encosto" de "esta ilha eu acabei de criar, então os quadrados dela
-- também são meus". Sem isso, um grupo novo na campanha nasce com a ilha no
-- lugar certo e o quadrado largado no chão do lobby.
local built = {}

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
-- ===== ILHA =====
-- A borda é uma peça a mais, mais larga e mais baixa: dá o "penhasco" de graça,
-- no mesmo estilo achatado do lobby, sem mesh nova.
local function BuildIsland(zone, parent)
	local span = LobbyZones.ISLAND_SPAN
	local thickness = LobbyZones.ISLAND_THICKNESS
	local center = Vector3.new(zone.center.X, LobbyZones.GROUND_Y, zone.center.Y)
	-- de esquadro com a ponte, que sai na diagonal: ilha quadrada sem girar
	-- encontra a ponte torta (ver `rotation` no LobbyZones)
	local spin = CFrame.Angles(0, math.rad(zone.rotation or 0), 0)

	NewPart(zone.id .. "_Rim",
		Vector3.new(span + 8, thickness * 1.6, span + 8),
		CFrame.new(center - Vector3.new(0, thickness * 0.9, 0)) * spin,
		zone.rim, Enum.Material.Rock, parent)

	local floor = NewPart(zone.id .. "_Floor",
		Vector3.new(span, thickness, span),
		CFrame.new(center - Vector3.new(0, thickness / 2, 0)) * spin,
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
end

-- ===== PONTE =====
-- Uma por zona, sempre do LOBBY até a ilha — o traçado é uma estrela, não uma
-- fila (ver o cabeçalho do LobbyZones).
--
-- Começa na BORDA do lobby, calculada pelo LobbyEdgeToward: o lobby é
-- retangular, então a saída pro norte e a saída pro leste ficam a distâncias
-- diferentes do centro. Antes isto era um `startInset` fixo que valia zero na
-- primeira ponte, e ela nascia no meio da grama e atravessava o lobby inteiro
-- por baixo.
local function BuildBridge(zone, index, parent)
	local from = LobbyZones.LobbyEdgeToward(zone.center)
	local a = Vector3.new(from.X, LobbyZones.GROUND_Y, from.Y)
	local b = Vector3.new(zone.center.X, LobbyZones.GROUND_Y, zone.center.Y)

	local direction = (b - a)
	local distance = direction.Magnitude
	if distance < 1 then return end
	direction = direction.Unit

	-- recorta o pedaço que cairia DENTRO da ilha: a ponte encosta na borda dela,
	-- senão atravessa o quadrado inteiro por baixo do chão
	local span = distance - LobbyZones.ISLAND_SPAN / 2
	if span <= 2 then return end

	local middle = a + direction * (span / 2)

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
-- A mesma peça é a água do vão: translúcida, sem colisão, logo abaixo da borda
-- das ilhas. Pra desligar, é só não chamar BuildFallNet no BuildTerrain.
local function TrailBounds(margin)
	local min, max = Vector2.new(1e9, 1e9), Vector2.new(-1e9, -1e9)
	local half = LobbyZones.ISLAND_SPAN / 2 + margin

	-- o lobby entra na conta junto das ilhas: a rede precisa cobrir o miolo da
	-- cruz também, senão quem cai de uma ponte perto de casa passa por dentro
	local pontos = { LobbyZones.LOBBY_CENTER }
	for _, zone in ipairs(LobbyZones.ZONES) do
		table.insert(pontos, zone.center)
	end

	for _, point in ipairs(pontos) do
		min = Vector2.new(math.min(min.X, point.X - half), math.min(min.Y, point.Y - half))
		max = Vector2.new(math.max(max.X, point.X + half), math.max(max.Y, point.Y + half))
	end
	return min, max
end

local NET_TOP_DROP = 16
local NET_HEIGHT = 80

local function BuildFallNet(folder)
	local old = folder:FindFirstChild("FallCatcher", true)
	if old then old:Destroy() end

	-- Margem larga: a rede precisa cobrir bem mais que as ilhas, senão quem
	-- pula com impulso passa POR FORA dela e cai assim mesmo.
	local min, max = TrailBounds(180)
	local span = max - min
	local center = (min + max) / 2

	local net = NewPart("FallCatcher",
		Vector3.new(span.X, NET_HEIGHT, span.Y),
		CFrame.new(center.X, LobbyZones.GROUND_Y - NET_TOP_DROP - NET_HEIGHT / 2, center.Y),
		Color3.fromRGB(36, 96, 150), Enum.Material.Water, folder)
	net.CanCollide = false
	net.Transparency = 0.35
	net.Reflectance = 0.15

	-- Devolve pro CENTRO do lobby, que agora é o eixo da cruz: de lá toda ilha
	-- fica a uma ponte, então quem caiu volta pertinho de onde estava indo.
	local casa = LobbyZones.LOBBY_CENTER
	local landing = CFrame.new(casa.X, LobbyZones.GROUND_Y + 4, casa.Y)

	net.Touched:Connect(function(hit)
		local character = hit.Parent
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and humanoid and humanoid.Health > 0 then
			root.AssemblyLinearVelocity = Vector3.zero
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

		-- Numa trilha adotada só mexe nos quadrados das ilhas que ACABARAM de
		-- nascer; o resto está onde o Studio deixou, e é lá que fica.
		if zone and (not adopted or built[zone.id]) then
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

-- ===== BORDA TEMÁTICA DA ILHA =====
-- Enfeita o PERÍMETRO de cada ilha com peças da cara dela: a beirada deixa de
-- ser um corte reto de laje e passa a parecer terreno que acaba. Vale só no
-- lobby — a trilha só existe fora de partida, então não há o que separar.
--
-- ISTO REABRE, DE PROPÓSITO, UMA PORTA QUE O LobbyZones FECHOU. Lá está escrito
-- que ilha nasce só com chão e borda porque vegetação gerada por código ficava
-- suja ao lado do que é montado à mão. A diferença aqui é o escopo: aquilo
-- espalhava mato pela ilha INTEIRA, disputando espaço com o cenário do Studio;
-- isto encosta só na beirada, que é justamente a parte que ninguém decora à mão.
-- Se voltar a sujar, apagar é uma linha — cada ilha tem a pasta <id>_Edge.
--
-- O tema mora AQUI e não no LobbyZones porque é decisão de cenário, não de
-- planta: o cliente nunca lê isto, só o construtor no servidor.
local EDGE_THEMES = {
	clareira  = { kind = "tuft",  color = Color3.fromRGB(86, 146, 70),   material = Enum.Material.LeafyGrass },
	bosque    = { kind = "spire", color = Color3.fromRGB(56, 48, 52),    material = Enum.Material.Wood },
	geleira   = { kind = "spire", color = Color3.fromRGB(168, 214, 240), material = Enum.Material.Ice },
	forja     = { kind = "block", color = Color3.fromRGB(46, 38, 36),    material = Enum.Material.Basalt },
	santuario = { kind = "block", color = Color3.fromRGB(196, 170, 142), material = Enum.Material.Sandstone },
}

local EDGE_SHAPES = {
	tuft  = { width = 4.6, height = 2.2 }, -- moita baixa e larga
	spire = { width = 2.2, height = 7.0 }, -- tronco/cristal fino e alto
	block = { width = 4.0, height = 3.0 }, -- lasca de pedra
}

local EDGE_PIECES = 30
local EDGE_INSET = 2.5 -- pra dentro da borda, senão a peça fica meio no ar

-- Ponto do perímetro em `t` (0..1 dá a volta completa), no espaço da PEÇA:
-- multiplicar pelo CFrame do chão real herda a rotação que a ilha ganhou à mão.
local function EdgeCFrame(floor, t)
	local halfX = floor.Size.X / 2 - EDGE_INSET
	local halfZ = floor.Size.Z / 2 - EDGE_INSET

	local side = math.floor(t * 4) % 4
	local u = (t * 4) % 1

	local lx, lz
	if side == 0 then
		lx, lz = -halfX + u * halfX * 2, -halfZ
	elseif side == 1 then
		lx, lz = halfX, -halfZ + u * halfZ * 2
	elseif side == 2 then
		lx, lz = halfX - u * halfX * 2, halfZ
	else
		lx, lz = -halfX, halfZ - u * halfZ * 2
	end

	return floor.CFrame * CFrame.new(lx, floor.Size.Y / 2, lz)
end

local function BuildZoneEdge(zone, trail, force)
	local spec = EDGE_THEMES[zone.id]
	-- Busca recursiva: o place agrupa ilha e ponte em Models feitos à mão, e o
	-- chão da Forja e do Santuário mora dentro de um deles.
	local floor = trail:FindFirstChild(zone.id .. "_Floor", true)
	if not spec or not (floor and floor:IsA("BasePart")) then return 0 end

	-- a borda montada à mão fica: só nasce a que ainda não existe, e `force`
	-- descarta a de lá pra gerar de novo (mesma regra da trilha inteira)
	local old = trail:FindFirstChild(zone.id .. "_Edge", true)
	if old and not force then return 0 end
	if old then old:Destroy() end

	local folder = Instance.new("Folder")
	folder.Name = zone.id .. "_Edge"
	folder.Parent = floor.Parent

	local shape = EDGE_SHAPES[spec.kind] or EDGE_SHAPES.block
	-- semente fixa por zona: reconstruir devolve a MESMA borda, não um sorteio
	-- novo a cada boot (o jogador reconhece o lugar pela silhueta dele)
	local rng = Random.new(zone.group * 7919)

	for index = 1, EDGE_PIECES do
		local t = ((index - 1) / EDGE_PIECES + rng:NextNumber(-0.012, 0.012)) % 1
		local base = EdgeCFrame(floor, t)

		local width = shape.width * rng:NextNumber(0.7, 1.3)
		local height = shape.height * rng:NextNumber(0.6, 1.4)

		local piece = NewPart(zone.id .. "_EdgePiece",
			Vector3.new(width, height, width * rng:NextNumber(0.7, 1.2)),
			base
				* CFrame.new(0, height / 2 - 1.2, 0)
				* CFrame.Angles(math.rad(rng:NextNumber(-9, 9)), rng:NextNumber(0, 6.28), math.rad(rng:NextNumber(-9, 9))),
			spec.color, spec.material, folder)

		-- Enfeite não é parede: um anel sólido fecharia a boca da ponte e
		-- prenderia o jogador dentro da própria ilha.
		piece.CanCollide = false
	end

	return EDGE_PIECES
end

-- Separada da BuildTerrain pra poder ser chamada sozinha da barra de comando
-- enquanto se acerta o visual:
--   require(game.ServerScriptService.Modules.LobbyZoneBuilder).BuildEdges()
--   require(game.ServerScriptService.Modules.LobbyZoneBuilder).BuildEdges(true)
function LobbyZoneBuilder.BuildEdges(force)
	local trail = Workspace:FindFirstChild(FOLDER_NAME)
	if not trail then
		warn("LobbyZoneBuilder: sem " .. FOLDER_NAME .. " — nada pra decorar.")
		return
	end

	local total = 0
	for _, zone in ipairs(LobbyZones.ZONES) do
		total += BuildZoneEdge(zone, trail, force)
	end

	print(("LobbyZoneBuilder: borda temática — %d peças novas (as que já existiam ficaram)."):format(total))
end

-- ===== ENTRADA =====
-- Terreno e quadrados são DUAS chamadas de propósito, e a ordem importa: quem
-- cria os pads que faltam é o GameStartTrigger, então ele levanta o terreno,
-- deixa os pads nascerem e só depois manda posicionar. Numa chamada só, o
-- PlacePads correria antes de o primeiro pad existir e não acharia nada.
function LobbyZoneBuilder.BuildTerrain(force)
	local existing = Workspace:FindFirstChild(FOLDER_NAME)

	if existing and not force then
		adopted = true
		built = {}

		-- Adotar não é ignorar: zona da planta que ainda NÃO tem chão no place é
		-- grupo novo da campanha, e essa precisa nascer. Busca recursiva porque
		-- o place agrupa ilha e ponte em Models feitos à mão.
		local novas = 0
		for index, zone in ipairs(LobbyZones.ZONES) do
			if not existing:FindFirstChild(zone.id .. "_Floor", true) then
				BuildIsland(zone, existing)
				BuildBridge(zone, index, existing)
				built[zone.id] = true
				novas += 1
			end
		end

		BuildFallNet(existing)

		-- Vale TAMBÉM na trilha adotada: a borda lê a peça de chão que está no
		-- place (posição e giro reais), então a ilha nova nasce alinhada com o
		-- que foi montado à mão. A borda que já existe não é tocada.
		LobbyZoneBuilder.BuildEdges()

		print(("LobbyZoneBuilder: %s já montado no place (%d peças) — trilha adotada, %d ilha(s) nova(s) levantada(s).")
			:format(FOLDER_NAME, #existing:GetDescendants(), novas))
		return
	end

	adopted = false
	built = {}
	if existing then existing:Destroy() end

	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = Workspace

	-- uma ilha e uma ponte por zona: a ponte de cada uma sai do lobby, então as
	-- duas coisas saem do mesmo laço em vez de uma cadeia de pares
	for index, zone in ipairs(LobbyZones.ZONES) do
		BuildIsland(zone, folder)
		BuildBridge(zone, index, folder)
		built[zone.id] = true
	end

	BuildFallNet(folder)
	LobbyZoneBuilder.BuildEdges()

	print(("LobbyZoneBuilder: %d zonas, %d pontes, %d peças (chão, borda temática e ponte).")
		:format(#LobbyZones.ZONES, #LobbyZones.ZONES, #folder:GetDescendants()))
end

-- Atalho pro modo Edit, onde não existe GameStartTrigger rodando pra ordenar as
-- duas metades.
function LobbyZoneBuilder.Build(force)
	LobbyZoneBuilder.BuildTerrain(force)
	LobbyZoneBuilder.PlacePads()
end

return LobbyZoneBuilder
