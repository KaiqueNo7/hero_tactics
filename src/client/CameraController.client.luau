--[[
	CameraController.client.lua
	LocalScript — StarterPlayer/StarterPlayerScripts

	Câmera fixa no ângulo calibrado, com zoom. F alterna pra voo livre de
	calibração (só ativo com SHOW_CAMERA_DEBUG=true): WASD move, E sobe,
	Q desce, botão direito olha em volta. O HUD loga elev/dist/fov/azim
	relativos ao centro do tabuleiro — os mesmos números usados nas
	constantes fixas, prontos pra copiar quando achar o ângulo ideal.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local StarterPlayer = game:GetService("StarterPlayer")

local HexGrid = require(ReplicatedStorage.Modules.HexGrid)
local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local BoardReady = ReplicatedStorage.Remotes:WaitForChild("BoardReady")
local MatchUpdate = ReplicatedStorage.Remotes:WaitForChild("MatchUpdate")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

-- ===== ENQUADRAMENTO (medido em jogo) =====
-- Calibrado no voo livre (F) e copiado do HUD: o log de lá usa a MESMA origem
-- (boardCenter) e a mesma convenção de ângulo do applyCamera, então os números
-- passam direto pra cá, sem conversão.
--
-- O azimute saiu de 16° pra 91°: o tabuleiro passou a ser visto quase de lado,
-- não mais de frente. Com a câmera um pouco mais alta e bem mais perto
-- (95 -> 75) as casas pegam mais luz e o hexágono fica menos achatado.
local FIELD_OF_VIEW = GameConfig.CAMERA_FOV
local ELEVATION = GameConfig.CAMERA_ELEVATION
local AZIMUTH = GameConfig.CAMERA_AZIMUTH
local DEFAULT_DISTANCE = GameConfig.CAMERA_DISTANCE
local FRAMING = 1.12

-- ===== ZOOM =====
-- O teto do zoom não é só gosto: ele decide se a câmera continua DENTRO do
-- diorama. O afastamento em X é 0.72 * raio (azimute 91°, elevação 44°), e o
-- piso da arena só vai até ARENA_CAMERA_MARGIN além do tabuleiro. Em 1.8 o raio
-- ia a 135 e a câmera saía ~73 studs além da borda — de fora, olhando o
-- cenário de trás, com o vazio preto aparecendo por baixo e pelas laterais.
-- 1.5 mantém ela dentro da margem nova do ArenaBuilder com folga.
local ZOOM_STEP = 5
local ZOOM_MIN_FACTOR, ZOOM_MAX_FACTOR = 0.45, 1.5

-- ===== MOVIMENTO NO LOBBY =====
-- Lidos do StarterPlayer pra devolver exatamente o que o place configurou, em
-- vez de chutar números. Este place usa JumpHeight (CharacterUseJumpPower =
-- false), então zerar/restaurar só o JumpPower não tem efeito nenhum.
local LOBBY_WALK_SPEED = StarterPlayer.CharacterWalkSpeed
local LOBBY_JUMP_POWER = StarterPlayer.CharacterJumpPower
local LOBBY_JUMP_HEIGHT = StarterPlayer.CharacterJumpHeight

-- ===== CALIBRAÇÃO =====
local SHOW_CAMERA_DEBUG = false -- true = mostra o HUD e libera o F pro voo livre
local FLY_SPEED = 40
local FLY_SPEED_FAST = 110
local LOOK_SENSITIVITY = 0.003

local activated = false
local boardCenter, baseRadius
local radius = 0
local minRadius, maxRadius = 0, 0
local debugLabel

local freeFlying = false
local flyLooking = false
local flyYaw, flyPitch = 0, 0

local FINISH_IN = 0.42
local FINISH_HOLD = 0.85
local FINISH_OUT = 0.5
local FINISH_RADIUS_FACTOR = 0.34
local FINISH_DRIFT = 0.9
local FINISH_FOV = 38
local FINISH_EYE_HEIGHT = 4
local FINISH_NAME_LIFT = 1.2

local finishToken = 0

local function orbitCFrame(center, distance)
	local az, el = math.rad(AZIMUTH), math.rad(ELEVATION)
	local horizontal = distance * math.cos(el)

	return CFrame.new(center + Vector3.new(
		math.sin(az) * horizontal,
		distance * math.sin(el),
		math.cos(az) * horizontal
	), center)
end

local function applyCamera()
	finishToken += 1

	local az, el = math.rad(AZIMUTH), math.rad(ELEVATION)
	local horizontal = radius * math.cos(el)

	local offset = Vector3.new(
		math.sin(az) * horizontal,
		radius * math.sin(el),
		math.cos(az) * horizontal
	)

	camera.CFrame = CFrame.new(boardCenter + offset, boardCenter)

	if debugLabel then
		debugLabel.Text = ("elev %.0f°   dist %.0f   fov %.0f   azim %.0f°   (F = voo livre)")
			:format(ELEVATION, radius, camera.FieldOfView, AZIMUTH)
	end
end

local function resetZoom()
	radius = baseRadius
	applyCamera()
end

local function buildDebugReadout()
	if not SHOW_CAMERA_DEBUG then return end

	local gui = Instance.new("ScreenGui")
	gui.Name = "CameraDebug"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = player:WaitForChild("PlayerGui")

	debugLabel = Instance.new("TextLabel")
	debugLabel.Size = UDim2.new(0, 340, 0, 20)
	debugLabel.Position = UDim2.new(0, 12, 0, 46)
	debugLabel.BackgroundTransparency = 1
	debugLabel.TextColor3 = Color3.fromRGB(200, 235, 255)
	debugLabel.TextStrokeTransparency = 0.4
	debugLabel.TextXAlignment = Enum.TextXAlignment.Left
	debugLabel.TextSize = 14
	debugLabel.Font = Enum.Font.Code
	debugLabel.Parent = gui
end

-- ===== VOO LIVRE DE CALIBRAÇÃO =====
local function logFreeFly()
	if not debugLabel then return end

	local vector = camera.CFrame.Position - boardCenter
	local dist = vector.Magnitude
	local elev = math.deg(math.asin(vector.Y / math.max(dist, 0.001)))
	local azim = math.deg(math.atan2(vector.X, vector.Z))

	debugLabel.Text = ("[VOO LIVRE] elev %.0f°   dist %.0f   fov %.0f   azim %.0f°   (F = travar)")
		:format(elev, dist, camera.FieldOfView, azim)
end

local function updateFreeFly(dt)
	if not freeFlying then return end

	local speed = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) and FLY_SPEED_FAST or FLY_SPEED
	local cf = camera.CFrame
	local move = Vector3.new()

	if UserInputService:IsKeyDown(Enum.KeyCode.W) then move += cf.LookVector end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) then move -= cf.LookVector end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) then move += cf.RightVector end
	if UserInputService:IsKeyDown(Enum.KeyCode.A) then move -= cf.RightVector end
	if UserInputService:IsKeyDown(Enum.KeyCode.E) then move += Vector3.new(0, 1, 0) end
	if UserInputService:IsKeyDown(Enum.KeyCode.Q) then move -= Vector3.new(0, 1, 0) end

	if move.Magnitude > 0 then
		camera.CFrame = camera.CFrame + move.Unit * speed * dt
	end

	logFreeFly()
end

local function toggleFreeFly()
	if not SHOW_CAMERA_DEBUG or not activated then return end

	freeFlying = not freeFlying

	if freeFlying then
		local rx, ry = camera.CFrame:ToOrientation()
		flyPitch, flyYaw = rx, ry
		logFreeFly()
	else
		if flyLooking then
			flyLooking = false
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end
		applyCamera()
	end
end

-- ===== PLATAFORMA E PERSONAGEM =====
local function buildStandPlatform(standPos, groundY)
	local existing = workspace:FindFirstChild("PlayerStand")
	if existing then existing:Destroy() end

	local platform = Instance.new("Part")
	platform.Name = "PlayerStand"
	platform.Size = Vector3.new(12, 1, 12)
	platform.CFrame = CFrame.new(standPos.X, groundY - 0.5, standPos.Z)
	platform.Anchored = true
	platform.CanCollide = true
	platform.Transparency = 1
	platform.CastShadow = false
	platform.Parent = workspace
end

-- No mobile, o thumbstick e o botão de pulo do Roblox ficam por cima do canto
-- inferior esquerdo da tela e comem o toque antes dele chegar no tabuleiro —
-- era por isso que as casas da esquerda não respondiam. Como o personagem fica
-- parado durante a partida, os controles são desligados por completo.
--
-- Só o controls:Disable() não bastava: o DynamicThumbstick deixa a TouchGui
-- montada, e o frame dele ocupa ~40% da esquerda da tela inteira. Ele aparece
-- como aquela mancha mais escura e continua engolindo o toque antes do
-- mouse.Target, então a metade esquerda do tabuleiro ficava morta. Desligar a
-- TouchGui junto tira as duas coisas durante a partida e devolve no lobby.
local controlsEnabled = true

local function applyTouchGui()
	local playerGui = player:FindFirstChild("PlayerGui")
	local touchGui = playerGui and playerGui:FindFirstChild("TouchGui")
	if touchGui then
		touchGui.Enabled = controlsEnabled
	end
end

-- a TouchGui é criada pelo PlayerModule depois que o script já rodou, e volta
-- a existir em alguns respawns: reaplica o estado atual quando ela aparecer
player:WaitForChild("PlayerGui").ChildAdded:Connect(function(child)
	if child.Name == "TouchGui" then
		task.defer(applyTouchGui)
	end
end)

local function setDefaultControls(enabled)
	controlsEnabled = enabled
	applyTouchGui()

	local playerScripts = player:FindFirstChild("PlayerScripts")
	local playerModule = playerScripts and playerScripts:FindFirstChild("PlayerModule")
	if not playerModule then return end

	local ok, controls = pcall(function()
		return require(playerModule):GetControls()
	end)
	if not ok or not controls then return end

	if enabled then
		controls:Enable()
	else
		controls:Disable()
	end
end

-- ===== MOVIMENTO DE LOBBY =====
-- Andar, pular e os controles na tela, do jeito que o place configurou. Separado
-- do returnToLobby porque precisa valer TAMBÉM pra quem acabou de entrar e pra
-- quem renasceu — dois casos em que o returnToLobby nem chega a rodar.
local function applyLobbyMovement(character)
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	humanoid.WalkSpeed = LOBBY_WALK_SPEED
	humanoid.JumpPower = LOBBY_JUMP_POWER
	humanoid.JumpHeight = LOBBY_JUMP_HEIGHT
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, true)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Landed, true)

	setDefaultControls(true)
end

-- ===== NASCER FORA DE PARTIDA JÁ VEM COM CONTROLE =====
-- O `controlsEnabled` é estado de MÓDULO e a TouchGui é recriada a cada
-- respawn: renascendo com a bandeira ainda em `false`, o applyTouchGui carimbava
-- esse `false` na GUI nova e o thumbstick e o botão de pulo não voltavam mais.
-- E não voltavam nem depois, porque o returnToLobby desiste na primeira linha
-- quando `activated` já é false — que é justamente o caso de quem saiu da
-- partida pela morte, pela desconexão, ou perdeu o MatchUpdate de "lobby".
--
-- A regra aqui é sem estado e vale ao contrário: TODO personagem que nasce fora
-- de uma partida nasce com movimento e controles de lobby. Cobre a primeira
-- entrada, o respawn e qualquer restauração que tenha se perdido no caminho.
player.CharacterAdded:Connect(function(character)
	if activated then return end
	applyLobbyMovement(character)
end)

-- O script pode subir DEPOIS do personagem já existir (é o caso comum na
-- primeira entrada), e aí o CharacterAdded acima nunca dispara pra ele.
if player.Character then
	task.defer(applyLobbyMovement, player.Character)
end

-- Altura em que o HumanoidRootPart descansa com o boneco de pé no chão.
-- Precisa ser medida DEPOIS do ScaleTo: as partes crescem junto, e um número
-- fixo (era "+3.5", cravado pra escala 1.6) enfia o boneco no piso ou o deixa
-- boiando assim que PLAYER_STAND_SCALE muda.
local function standingRootHeight(character, humanoid, rootPart)
	-- R15 declara a altura do quadril; R6 não usa HipHeight (fica 0) e apoia o
	-- root no meio do torso, então a perna é quem dá a medida — e ela acompanha
	-- a escala do mesmo jeito.
	if humanoid.RigType == Enum.HumanoidRigType.R6 then
		local leg = character:FindFirstChild("Left Leg")
		return (leg and leg.Size.Y or 2) + rootPart.Size.Y / 2
	end

	return humanoid.HipHeight + rootPart.Size.Y / 2
end

local function placeCharacter(character, standPos, lookAt)
	local humanoid = character:WaitForChild("Humanoid")
	local rootPart = character:WaitForChild("HumanoidRootPart")

	pcall(function()
		character:ScaleTo(GameConfig.PLAYER_STAND_SCALE)
	end)

	-- standPos vem no nível do CHÃO; a altura do boneco entra aqui. O alvo do
	-- olhar sobe junto, senão o personagem encara o piso em vez do adversário.
	local restY = standPos.Y + standingRootHeight(character, humanoid, rootPart)
	rootPart.CFrame = CFrame.new(
		Vector3.new(standPos.X, restY, standPos.Z),
		Vector3.new(lookAt.X, restY, lookAt.Z)
	)

	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	humanoid.JumpHeight = 0
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, false)

	setDefaultControls(false)
end

-- Só spawns perto do centro do lobby. Os 19 pontos se espalham até ~30 studs,
-- e o pad de PvP está a ~33 — voltar pro lobby podia jogar o jogador em cima
-- do pad e disparar a fila sozinho.
local function lobbyCFrame()
	local spawnsFolder = workspace:FindFirstChild("Folder") and workspace.Folder:FindFirstChild("Lobby")
	spawnsFolder = spawnsFolder and spawnsFolder:FindFirstChild("Spawns")

	local parts = {}
	local sum = Vector3.new()

	if spawnsFolder then
		for _, child in ipairs(spawnsFolder:GetChildren()) do
			if child:IsA("BasePart") then
				table.insert(parts, child)
				sum += child.Position
			end
		end
	end

	if #parts == 0 then
		local fallback = workspace:FindFirstChild("SpawnLocation", true)
		return fallback and (fallback.CFrame + Vector3.new(0, 3, 0)) or CFrame.new(0, 5, 0)
	end

	local center = sum / #parts
	local near = {}
	for _, part in ipairs(parts) do
		local flat = Vector3.new(part.Position.X - center.X, 0, part.Position.Z - center.Z)
		if flat.Magnitude <= GameConfig.LOBBY_SPAWN_RADIUS then
			table.insert(near, part)
		end
	end

	local pool = #near > 0 and near or parts
	return pool[math.random(#pool)].CFrame + Vector3.new(0, 3, 0)
end

local function returnToLobby()
	if not activated then return end
	activated = false
	freeFlying = false

	local platform = workspace:FindFirstChild("PlayerStand")
	if platform then platform:Destroy() end

	camera.CameraType = Enum.CameraType.Custom
	setDefaultControls(true) -- devolve o thumbstick pra andar pelo lobby

	local character = player.Character
	if character then
		pcall(function()
			character:ScaleTo(1)
		end)

		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local rootPart = character:FindFirstChild("HumanoidRootPart")

		if humanoid then
			camera.CameraSubject = humanoid
		end
		applyLobbyMovement(character)

		if rootPart then
			rootPart.CFrame = lobbyCFrame()
		end
	end
end

-- slot 1 ou 2: define de que lado do tabuleiro o personagem fica de pé.
-- A câmera é a MESMA pros dois lados — o tabuleiro não espelha.
local function activateBoardCamera(hexSize, boardOffset, slot)
	if activated then return end
	activated = true

	HexGrid.SetHexSize(hexSize)
	HexGrid.SetBoardOffset(boardOffset)
	HexGrid.Generate()

	local minV, maxV = HexGrid.GetBoardBounds()
	boardCenter = HexGrid.GetBoardCenter()

	camera.FieldOfView = FIELD_OF_VIEW

	if DEFAULT_DISTANCE > 0 then
		baseRadius = DEFAULT_DISTANCE
	else
		local width = maxV.X - minV.X
		local depth = (maxV.Z - minV.Z) * math.sin(math.rad(ELEVATION))
		baseRadius = (math.max(width, depth) / 2)
			/ math.tan(math.rad(FIELD_OF_VIEW / 2)) * FRAMING
	end

	minRadius = baseRadius * ZOOM_MIN_FACTOR
	maxRadius = baseRadius * ZOOM_MAX_FACTOR

	local groundY = boardOffset.Y
	local standPos = HexGrid.GetStandPosition(slot or 1, groundY)
	local lookAt = HexGrid.GetStandFacing(slot or 1, standPos)

	buildStandPlatform(standPos, groundY)
	placeCharacter(player.Character or player.CharacterAdded:Wait(), standPos, lookAt)

	player.CharacterAdded:Connect(function(newCharacter)
		if activated then
			placeCharacter(newCharacter, standPos, lookAt)
		end
	end)

	camera.CameraType = Enum.CameraType.Scriptable
	camera:GetPropertyChangedSignal("CameraType"):Connect(function()
		if activated and camera.CameraType ~= Enum.CameraType.Scriptable then
			camera.CameraType = Enum.CameraType.Scriptable
		end
	end)

	buildDebugReadout()
	resetZoom()
end

-- ===== CONTROLES =====
UserInputService.InputBegan:Connect(function(input, processed)
	if not activated or processed then return end

	if input.KeyCode == Enum.KeyCode.R then
		if not freeFlying then resetZoom() end
	elseif input.KeyCode == Enum.KeyCode.F then
		toggleFreeFly()
	elseif freeFlying and input.UserInputType == Enum.UserInputType.MouseButton2 then
		flyLooking = true
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton2 and flyLooking then
		flyLooking = false
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
end)

UserInputService.InputChanged:Connect(function(input, processed)
	if not activated or processed then return end

	if freeFlying then
		if flyLooking and input.UserInputType == Enum.UserInputType.MouseMovement then
			flyYaw -= input.Delta.X * LOOK_SENSITIVITY
			flyPitch = math.clamp(flyPitch - input.Delta.Y * LOOK_SENSITIVITY, -math.rad(85), math.rad(85))
			camera.CFrame = CFrame.new(camera.CFrame.Position)
				* CFrame.Angles(0, flyYaw, 0) * CFrame.Angles(flyPitch, 0, 0)
		end
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseWheel then
		radius = math.clamp(radius - input.Position.Z * ZOOM_STEP, minRadius, maxRadius)
		applyCamera()
	end
end)

-- ===== ZOOM POR PINÇA (mobile) =====
-- UserInputService.TouchPinch é um evento cru, independente de CameraType —
-- por isso o zoom de mouse funcionava e o de celular não: não existia
-- nenhum código escutando o gesto.
local pinchStartRadius = 0

UserInputService.TouchPinch:Connect(function(_touchPositions, scale, _velocity, state, processed)
	if not activated or freeFlying or processed then return end

	if state == Enum.UserInputState.Begin then
		pinchStartRadius = radius
	elseif state == Enum.UserInputState.Change then
		-- afastar os dedos (scale > 1) = zoom in = distância menor
		radius = math.clamp(pinchStartRadius / scale, minRadius, maxRadius)
		applyCamera()
	end
end)

RunService.RenderStepped:Connect(function(dt)
	if freeFlying then
		updateFreeFly(dt)
	end
end)

BoardReady.OnClientEvent:Connect(activateBoardCamera)

local function buildFinishNameplate(position, name, sideIndex)
	local anchor = Instance.new("Part")
	anchor.Name = "FinishNameplate"
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = CFrame.new(position + Vector3.new(0, FINISH_NAME_LIFT, 0))
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Parent = workspace

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Name"
	billboard.Size = UDim2.fromOffset(420, 64)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.MaxDistance = math.huge
	billboard.Parent = anchor

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = name:upper()
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeColor3 = sideIndex == 2
		and Color3.fromRGB(70, 8, 10) or Color3.fromRGB(6, 18, 48)
	label.TextScaled = true
	label.Font = Enum.Font.GothamBlack

	local limit = Instance.new("UITextSizeConstraint")
	limit.MaxTextSize = 38
	limit.Parent = label

	local outlines = {}
	for _, shift in ipairs({ { -2, 0 }, { 2, 0 }, { 0, -2 }, { 0, 2 } }) do
		local copy = label:Clone()
		copy.Position = UDim2.fromOffset(shift[1], shift[2])
		copy.TextColor3 = label.TextStrokeColor3
		copy.TextStrokeTransparency = 1
		copy.ZIndex = 1
		copy.Parent = billboard
		table.insert(outlines, copy)
	end

	label.ZIndex = 2
	label.Parent = billboard

	return anchor, label, outlines
end

local function playFinishCam(info)
	if not (activated and boardCenter and info and info.hex) then return end
	if freeFlying then return end

	local ok, target = pcall(HexGrid.GetWorldPosition, info.hex)
	if not (ok and target) then return end

	local focus = target + Vector3.new(0, FINISH_EYE_HEIGHT, 0)
	local wide = camera.CFrame
	local baseFov = camera.FieldOfView
	local close = math.max(radius * FINISH_RADIUS_FACTOR, minRadius * 0.5)

	finishToken += 1
	local token = finishToken

	local plate, label, outlines = nil, nil, {}
	if info.name then
		plate, label, outlines = buildFinishNameplate(target, info.name, info.sideIndex)
	end

	local function fadeName(alpha)
		if not label then return end

		label.TextTransparency = alpha
		label.TextStrokeTransparency = alpha
		for _, copy in ipairs(outlines) do
			copy.TextTransparency = alpha
		end
	end

	local function dropName()
		if plate then plate:Destroy() end
		plate, label, outlines = nil, nil, {}
	end

	fadeName(1)

	task.spawn(function()
		local elapsed = 0
		while elapsed < FINISH_IN do
			elapsed += RunService.RenderStepped:Wait()
			if finishToken ~= token then dropName() return end

			local a = math.min(elapsed / FINISH_IN, 1)
			a = a * a * (3 - 2 * a)
			camera.CFrame = wide:Lerp(orbitCFrame(focus, close), a)
			camera.FieldOfView = baseFov + (FINISH_FOV - baseFov) * a
			fadeName(1 - a)
		end

		elapsed = 0
		while elapsed < FINISH_HOLD do
			elapsed += RunService.RenderStepped:Wait()
			if finishToken ~= token then dropName() return end

			local a = math.min(elapsed / FINISH_HOLD, 1)
			camera.CFrame = orbitCFrame(focus, close - FINISH_DRIFT * a)
		end

		local from = camera.CFrame
		elapsed = 0
		while elapsed < FINISH_OUT do
			elapsed += RunService.RenderStepped:Wait()
			if finishToken ~= token then dropName() return end

			local a = math.min(elapsed / FINISH_OUT, 1)
			a = a * a * (3 - 2 * a)
			camera.CFrame = from:Lerp(wide, a)
			camera.FieldOfView = FINISH_FOV + (baseFov - FINISH_FOV) * a
			fadeName(a)
		end

		dropName()

		if finishToken ~= token then return end
		camera.FieldOfView = baseFov
		applyCamera()
	end)
end

MatchUpdate.OnClientEvent:Connect(function(state)
	if state.phase == "lobby" then
		returnToLobby()
		return
	end

	if state.finisher and state.phase ~= "finished" then
		playFinishCam(state.finisher)
	end
end)
