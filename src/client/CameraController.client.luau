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
local FIELD_OF_VIEW = 38
local ELEVATION = 35
local AZIMUTH = 13
local DEFAULT_DISTANCE = 89
local FRAMING = 1.12

-- ===== ZOOM =====
local ZOOM_STEP = 5
local ZOOM_MIN_FACTOR, ZOOM_MAX_FACTOR = 0.45, 1.8

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

local function applyCamera()
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

local function placeCharacter(character, standPos, lookAt)
	local humanoid = character:WaitForChild("Humanoid")
	local rootPart = character:WaitForChild("HumanoidRootPart")

	rootPart.CFrame = CFrame.new(standPos, lookAt)

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
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local rootPart = character:FindFirstChild("HumanoidRootPart")

		if humanoid then
			camera.CameraSubject = humanoid
			humanoid.WalkSpeed = LOBBY_WALK_SPEED
			humanoid.JumpPower = LOBBY_JUMP_POWER
			humanoid.JumpHeight = LOBBY_JUMP_HEIGHT
			humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
			humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, true)
			humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)
			humanoid:SetStateEnabled(Enum.HumanoidStateType.Landed, true)
		end

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
	local standPos = HexGrid.GetStandPosition(slot or 1, groundY + 3.5)
	local lookAt = Vector3.new(boardCenter.X, standPos.Y, boardCenter.Z)

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

MatchUpdate.OnClientEvent:Connect(function(state)
	if state.phase == "lobby" then
		returnToLobby()
	end
end)
