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

local adopted = false

local built = {}

local function NewPart(name, size, cframe, color, material, parent)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.CanCollide = true
	part.CastShadow = false
	part.Parent = parent
	return part
end

local function BuildIsland(zone, parent)
	local span = LobbyZones.ISLAND_SPAN
	local thickness = LobbyZones.ISLAND_THICKNESS
	local center = Vector3.new(zone.center.X, LobbyZones.GROUND_Y, zone.center.Y)
	local spin = CFrame.Angles(0, math.rad(zone.rotation or 0), 0)

	NewPart(zone.id .. "_Rim",
		Vector3.new(span + 8, thickness * 1.6, span + 8),
		CFrame.new(center - Vector3.new(0, thickness * 0.9, 0)) * spin,
		zone.rim, Enum.Material.Rock, parent)

	local floor = NewPart(zone.id .. "_Floor",
		Vector3.new(span, thickness, span),
		CFrame.new(center - Vector3.new(0, thickness / 2, 0)) * spin,
		zone.ground.color, zone.ground.material, parent)
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

local function TrailBounds(margin)
	local min, max = Vector2.new(1e9, 1e9), Vector2.new(-1e9, -1e9)
	local half = LobbyZones.ISLAND_SPAN / 2 + margin

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

function LobbyZoneBuilder.IslandTop(name)
	if not name then return nil end

	local trail = Workspace:FindFirstChild("LobbyTrail")
	local island = trail and trail:FindFirstChild(name, true)
	if not island then return nil end

	if island:IsA("BasePart") then
		return island.Position + Vector3.new(0, island.Size.Y / 2 + 0.5, 0)
	end

	if island:IsA("Model") then
		local pivot, size = island:GetBoundingBox()
		return pivot.Position + Vector3.new(0, size.Y / 2 + 0.5, 0)
	end

	return nil
end

function LobbyZoneBuilder.PlacePads()
	local rows, order = {}, {}
	for _, fight in ipairs(Campaign.FIGHTS) do
		local key = fight.island or fight.group
		if not rows[key] then
			rows[key] = { group = fight.group, island = fight.island, fights = {} }
			table.insert(order, key)
		end
		table.insert(rows[key].fights, fight)
	end

	local moved, kept = 0, 0

	for _, key in ipairs(order) do
		local row = rows[key]
		local fights = row.fights
		local zone = not row.island and LobbyZones.ForGroup(row.group) or nil
		local anchor = LobbyZoneBuilder.IslandTop(row.island)

		if zone or anchor then
			local slots = LobbyZones.PadSlots(zone, #fights, anchor)
			local zoneIsNew = zone ~= nil and (not adopted or built[zone.id])

			for index, fight in ipairs(fights) do
				local pad = Workspace:FindFirstChild("FightPad_" .. fight.hero, true)
				if pad and pad:IsA("BasePart") then
					-- Numa trilha adotada, o que o Studio montou fica onde está: só
					-- o quadrado recém-criado (TrailPending) é encaixado na planta.
					local mayMove = zoneIsNew or pad:GetAttribute("TrailPending")

					if pad:GetAttribute("KeepPosition") then
						kept += 1
					elseif mayMove then
						-- CFrame e não Position: pad adotado do place pode vir
						-- torto, e um quadrado inclinado é uma rampa que joga o
						-- jogador pra fora da ilha
						pad.CFrame = CFrame.new(slots[index])
						pad:SetAttribute("TrailZone", zone and zone.id or row.island)
						pad:SetAttribute("TrailPending", nil)
						moved += 1
					end
				end
			end
		end
	end

	print(("LobbyZoneBuilder: %d quadrados posicionados na trilha (%d preservados por KeepPosition).")
		:format(moved, kept))
end

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

	for index, zone in ipairs(LobbyZones.ZONES) do
		BuildIsland(zone, folder)
		BuildBridge(zone, index, folder)
		built[zone.id] = true
	end

	BuildFallNet(folder)

	print(("LobbyZoneBuilder: %d zonas, %d pontes, %d peças (chão, borda temática e ponte).")
		:format(#LobbyZones.ZONES, #LobbyZones.ZONES, #folder:GetDescendants()))
end

function LobbyZoneBuilder.Build(force)
	LobbyZoneBuilder.BuildTerrain(force)
	LobbyZoneBuilder.PlacePads()
end

return LobbyZoneBuilder
