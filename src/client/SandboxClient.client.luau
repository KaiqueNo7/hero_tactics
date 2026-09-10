local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local StarterGui = game:GetService("StarterGui")
local GuiService = game:GetService("GuiService")
local Lighting = game:GetService("Lighting")

if not RunService:IsStudio() then return end

local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local HexGrid = require(ReplicatedStorage.Modules.HexGrid)
local GameAction = ReplicatedStorage.Remotes:WaitForChild("GameAction")
local MatchUpdate = ReplicatedStorage.Remotes:WaitForChild("MatchUpdate")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera
local mouse = player:GetMouse()

local ui = {}
local cam = { points = {}, token = 0 }
local cine = { hidden = {}, on = false, slowmo = false }
local sb = { ready = false, pick = false, hudOn = true, snapshot = nil, lines = {} }

local LOCAL = {}

local function Log(text)
	table.insert(sb.lines, text)
	while #sb.lines > 7 do table.remove(sb.lines, 1) end
	if ui.log then ui.log.Text = table.concat(sb.lines, "\n") end
	print("[Sandbox] " .. text)
end

local function Words(text)
	local out = {}
	for word in string.gmatch(text, "[^%s]+") do table.insert(out, word) end
	table.remove(out, 1)
	return out
end

local function Run(text)
	if type(text) ~= "string" or text == "" then return end

	local first = string.lower(string.match(text, "^%s*(%S+)") or "")
	local handler = LOCAL[first]

	if handler then
		handler(Words(text))
	else
		GameAction:FireServer("sandbox", text)
	end
end

local function BoardCenter()
	local ok, center = pcall(HexGrid.GetBoardCenter)
	return ok and center or Vector3.new(0, 0, 0)
end

local function HeroPart(token)
	local snapshot = sb.snapshot
	local folder = snapshot and snapshot.heroesFolder
	if not (folder and folder.Parent and token) then return nil end

	local lower = string.lower(token)
	for _, hero in ipairs(snapshot.heroes or {}) do
		if string.lower(hero.name) == lower or string.lower(hero.uid) == lower then
			return folder:FindFirstChild(hero.uid)
		end
	end
	for _, hero in ipairs(snapshot.heroes or {}) do
		if string.find(string.lower(hero.name), lower, 1, true) then
			return folder:FindFirstChild(hero.uid)
		end
	end
	return nil
end

local function TargetPosition(token)
	local part = HeroPart(token)
	if part then return part.Position end

	local hexId = token and string.upper(token) or ""
	if HexGrid.Exists(hexId) then
		return HexGrid.GetWorldPosition(hexId) + Vector3.new(0, 4, 0)
	end
	return nil
end

local function Glide(goal, seconds)
	cam.token += 1
	local token = cam.token

	if not seconds or seconds <= 0 then
		camera.CFrame = goal
		return
	end

	local from = camera.CFrame
	task.spawn(function()
		local elapsed = 0
		while elapsed < seconds do
			elapsed += RunService.RenderStepped:Wait()
			if cam.token ~= token then return end
			local a = math.clamp(elapsed / seconds, 0, 1)
			camera.CFrame = from:Lerp(goal, a * a * (3 - 2 * a))
		end
	end)
end

local function Orbit(seconds, degrees)
	cam.token += 1
	local token = cam.token

	local center = BoardCenter()
	local offset = camera.CFrame.Position - center
	local height = offset.Y
	local flat = Vector3.new(offset.X, 0, offset.Z).Magnitude
	local startAngle = math.atan2(offset.X, offset.Z)

	task.spawn(function()
		local elapsed = 0
		while elapsed < seconds do
			elapsed += RunService.RenderStepped:Wait()
			if cam.token ~= token then return end

			local a = math.clamp(elapsed / seconds, 0, 1)
			local angle = startAngle + math.rad(degrees) * a
			camera.CFrame = CFrame.new(
				center + Vector3.new(math.sin(angle) * flat, height, math.cos(angle) * flat),
				center)
		end
	end)
end

LOCAL.cam = function(words)
	local action = string.lower(words[1] or "")

	if action == "mark" then
		local name = string.upper(words[2] or "A")
		cam.points[name] = camera.CFrame
		Log("ponto " .. name .. " marcado")

	elseif action == "go" then
		local goal = cam.points[string.upper(words[2] or "A")]
		if goal then Glide(goal, tonumber(words[3]) or 0) else Log("ponto vazio") end

	elseif action == "fly" then
		local from = cam.points[string.upper(words[2] or "A")]
		local to = cam.points[string.upper(words[3] or "B")]
		if not (from and to) then Log("marque os dois pontos antes") return end
		camera.CFrame = from
		task.wait()
		Glide(to, tonumber(words[4]) or 4)

	elseif action == "focus" then
		local position = TargetPosition(words[2])
		if not position then Log("alvo desconhecido: " .. tostring(words[2])) return end
		Glide(GameConfig.MatchCameraCFrame(position, tonumber(words[3]) or 32), tonumber(words[4]) or 0)

	elseif action == "pair" then
		local one = TargetPosition(words[2])
		local two = TargetPosition(words[3])
		if not (one and two) then Log("preciso de dois alvos") return end
		local middle = (one + two) / 2
		local span = (one - two).Magnitude
		Glide(GameConfig.MatchCameraCFrame(middle, math.max(span * 1.6, 26)), tonumber(words[4]) or 0)

	elseif action == "orbit" then
		Orbit(tonumber(words[2]) or 6, tonumber(words[3]) or 40)

	elseif action == "zoom" then
		local distance = tonumber(words[2]) or GameConfig.CAMERA_DISTANCE
		Glide(GameConfig.MatchCameraCFrame(BoardCenter(), distance), tonumber(words[3]) or 0)

	elseif action == "fov" then
		camera.FieldOfView = math.clamp(tonumber(words[2]) or GameConfig.CAMERA_FOV, 5, 110)

	elseif action == "stop" then
		cam.token += 1

	elseif action == "reset" then
		cam.token += 1
		camera.FieldOfView = GameConfig.CAMERA_FOV
		camera.CFrame = GameConfig.MatchCameraCFrame(BoardCenter())

	else
		Log("cam: mark|go|fly|focus|pair|orbit|zoom|fov|stop|reset")
	end
end

local function SetCharacterVisible(visible)
	local character = player.Character
	if not character then return end

	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") or part:IsA("Decal") then
			part.LocalTransparencyModifier = visible and 0 or 1
		end
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayDistanceType = visible
			and Enum.HumanoidDisplayDistanceType.Viewer
			or Enum.HumanoidDisplayDistanceType.None
	end
end

local function ApplyCursor()
	local panelVisible = ui.panel ~= nil and ui.panel.Visible
	local wanted = panelVisible or (sb.hudOn and not cine.on)

	if UserInputService.MouseIconEnabled ~= wanted then
		UserInputService.MouseIconEnabled = wanted
	end
end

local function EnforceHidden()
	for _, gui in ipairs(player.PlayerGui:GetChildren()) do
		if gui:IsA("ScreenGui") and gui.Name ~= "SandboxGui" and gui.Enabled then
			gui.Enabled = false
			cine.hidden[gui] = true
		end
	end
	if cine.on then SetCharacterVisible(false) end
	ApplyCursor()
end

local function SetHud(on)
	sb.hudOn = on
	pcall(function() StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, on) end)
	pcall(function() StarterGui:SetCore("TopbarEnabled", on) end)
	pcall(function() GuiService.TouchControlsEnabled = on end)

	if on then
		if cine.guard then
			cine.guard:Disconnect()
			cine.guard = nil
		end
		for gui in pairs(cine.hidden) do
			if gui.Parent then gui.Enabled = true end
		end
		table.clear(cine.hidden)
	else
		EnforceHidden()
		cine.guard = cine.guard or RunService.Heartbeat:Connect(EnforceHidden)
	end

	ApplyCursor()
end

local function SetSlowmo(on)
	cine.slowmo = on

	if on then
		cine.blur = cine.blur or Instance.new("BlurEffect")
		cine.blur.Name = "SandboxBlur"
		cine.blur.Size = 8
		cine.blur.Parent = Lighting

		cine.grade = cine.grade or Instance.new("ColorCorrectionEffect")
		cine.grade.Name = "SandboxGrade"
		cine.grade.Saturation = -0.2
		cine.grade.Contrast = 0.08
		cine.grade.Parent = Lighting
	else
		if cine.blur then cine.blur:Destroy() cine.blur = nil end
		if cine.grade then cine.grade:Destroy() cine.grade = nil end
	end
end

local function SetCine(on)
	cine.on = on
	SetHud(not on)
	SetCharacterVisible(not on)
	if ui.SetOpen then ui.SetOpen(not on and ui.panel.Visible) end
	if ui.handle then ui.handle.Visible = not on end
	if not on then SetSlowmo(false) end
	ApplyCursor()
end

LOCAL.hud = function(words)
	SetHud(string.lower(words[1] or "on") ~= "off")
end

LOCAL.cine = function(words)
	local first = string.lower(words[1] or "on")

	if first == "slowmo" then
		SetSlowmo(string.lower(words[2] or "on") ~= "off")
		return
	end

	SetCine(first ~= "off")
end

LOCAL.panel = function()
	if ui.SetOpen then ui.SetOpen(not ui.panel.Visible) end
	ApplyCursor()
end

LOCAL.pick = function(words)
	sb.pick = string.lower(words[1] or "on") ~= "off"
	Log(sb.pick and "clique numa casa pra copiar o nome dela" or "clique livre")
end

local function Button(text, parent, onClick)
	local button = Instance.new("TextButton")
	button.Size = UDim2.fromOffset(74, 24)
	button.BackgroundColor3 = Color3.fromRGB(38, 42, 54)
	button.BorderSizePixel = 0
	button.Text = text
	button.TextColor3 = Color3.fromRGB(210, 220, 235)
	button.TextSize = 12
	button.Font = Enum.Font.Code
	button.Parent = parent
	button.Activated:Connect(onClick)

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = button

	return button
end

local function BuildUi()
	if ui.gui then return end

	ui.gui = Instance.new("ScreenGui")
	ui.gui.Name = "SandboxGui"
	ui.gui.DisplayOrder = 50
	ui.gui.ResetOnSpawn = false
	ui.gui.IgnoreGuiInset = true
	ui.gui.Parent = player:WaitForChild("PlayerGui")

	-- ===== PUXADOR =====
	-- O painel de 470x250 come metade da tela de um celular em pé, e ele é
	-- ferramenta de autor: fica fechado por padrão e abre no toque. O F2 continua
	-- valendo pra quem está no teclado.
	--
	-- Fora do Studio este arquivo inteiro nem chega aqui (o SandboxService devolve
	-- no-op), então o puxador só existe pra quem está desenvolvendo.
	ui.handle = Instance.new("TextButton")
	ui.handle.Name = "SandboxHandle"
	ui.handle.AnchorPoint = Vector2.new(0, 1)
	ui.handle.Position = UDim2.new(0, 12, 1, -12)
	ui.handle.Size = UDim2.fromOffset(104, 30)
	ui.handle.BackgroundColor3 = Color3.fromRGB(20, 24, 34)
	ui.handle.BackgroundTransparency = 0.1
	ui.handle.BorderSizePixel = 0
	ui.handle.Text = "SANDBOX ▲"
	ui.handle.TextColor3 = Color3.fromRGB(150, 200, 240)
	ui.handle.TextSize = 12
	ui.handle.Font = Enum.Font.GothamBold
	ui.handle.ZIndex = 3
	ui.handle.Parent = ui.gui

	local handleCorner = Instance.new("UICorner")
	handleCorner.Name = "HandleCorner"
	handleCorner.CornerRadius = UDim.new(0, 8)
	handleCorner.Parent = ui.handle

	ui.panel = Instance.new("Frame")
	ui.panel.Name = "SandboxPanel"
	-- Escala com teto: numa tela estreita ele encolhe junto em vez de sair pela
	-- direita, e numa tela larga para de crescer no tamanho que sempre teve.
	ui.panel.Size = UDim2.new(0.94, 0, 0, 250)
	ui.panel.Position = UDim2.new(0, 12, 1, -50)
	ui.panel.AnchorPoint = Vector2.new(0, 1)
	ui.panel.BackgroundColor3 = Color3.fromRGB(14, 16, 22)
	ui.panel.BackgroundTransparency = 0.15
	ui.panel.BorderSizePixel = 0
	ui.panel.Visible = false
	ui.panel.Parent = ui.gui

	local panelSize = Instance.new("UISizeConstraint")
	panelSize.Name = "PanelSize"
	panelSize.MaxSize = Vector2.new(470, math.huge)
	panelSize.Parent = ui.panel

	local function SetOpen(open)
		ui.panel.Visible = open
		ui.handle.Text = open and "SANDBOX ▼" or "SANDBOX ▲"
	end

	ui.handle.Activated:Connect(function()
		SetOpen(not ui.panel.Visible)
	end)

	ui.SetOpen = SetOpen

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = ui.panel

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -16, 0, 20)
	title.Position = UDim2.fromOffset(8, 6)
	title.BackgroundTransparency = 1
	title.Text = "SANDBOX — toque no puxador ou F2 pra fechar, F voa a câmera"
	title.TextColor3 = Color3.fromRGB(120, 200, 255)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextSize = 12
	title.Font = Enum.Font.Code
	title.Parent = ui.panel

	ui.log = Instance.new("TextLabel")
	ui.log.Size = UDim2.new(1, -16, 0, 96)
	ui.log.Position = UDim2.fromOffset(8, 28)
	ui.log.BackgroundTransparency = 1
	ui.log.Text = ""
	ui.log.TextColor3 = Color3.fromRGB(180, 190, 205)
	ui.log.TextXAlignment = Enum.TextXAlignment.Left
	ui.log.TextYAlignment = Enum.TextYAlignment.Top
	ui.log.TextSize = 12
	ui.log.Font = Enum.Font.Code
	ui.log.Parent = ui.panel

	ui.input = Instance.new("TextBox")
	ui.input.Size = UDim2.new(1, -16, 0, 26)
	ui.input.Position = UDim2.fromOffset(8, 128)
	ui.input.BackgroundColor3 = Color3.fromRGB(28, 32, 42)
	ui.input.BorderSizePixel = 0
	ui.input.ClearTextOnFocus = false
	ui.input.PlaceholderText = "spawn Nash 1 C3   (help lista tudo)"
	ui.input.Text = ""
	ui.input.TextColor3 = Color3.fromRGB(235, 240, 250)
	ui.input.TextXAlignment = Enum.TextXAlignment.Left
	ui.input.TextSize = 13
	ui.input.Font = Enum.Font.Code
	ui.input.Parent = ui.panel

	local inputCorner = Instance.new("UICorner")
	inputCorner.CornerRadius = UDim.new(0, 4)
	inputCorner.Parent = ui.input

	ui.input.FocusLost:Connect(function(enterPressed)
		if not enterPressed then return end
		local text = ui.input.Text
		ui.input.Text = ""
		Run(text)
	end)

	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, -16, 0, 24)
	row.Position = UDim2.fromOffset(8, 160)
	row.BackgroundTransparency = 1
	row.Parent = ui.panel

	local rowLayout = Instance.new("UIListLayout")
	rowLayout.FillDirection = Enum.FillDirection.Horizontal
	rowLayout.Padding = UDim.new(0, 4)
	rowLayout.Parent = row

	Button("ABRIR", row, function() Run("open random") end)
	Button("HUD", row, function() SetHud(not sb.hudOn) end)
	Button("CINE", row, function() SetCine(not cine.on) end)
	Button("SLOWMO", row, function() SetSlowmo(not cine.slowmo) end)
	Button("CASA", row, function() LOCAL.pick({ sb.pick and "off" or "on" }) end)
	Button("RESET", row, function() Run("reset") end)

	ui.presets = Instance.new("ScrollingFrame")
	ui.presets.Size = UDim2.new(1, -16, 0, 52)
	ui.presets.Position = UDim2.fromOffset(8, 190)
	ui.presets.BackgroundTransparency = 1
	ui.presets.BorderSizePixel = 0
	ui.presets.ScrollBarThickness = 4
	ui.presets.CanvasSize = UDim2.fromOffset(0, 0)
	ui.presets.AutomaticCanvasSize = Enum.AutomaticSize.Y
	ui.presets.Parent = ui.panel

	local presetLayout = Instance.new("UIGridLayout")
	presetLayout.CellSize = UDim2.fromOffset(148, 22)
	presetLayout.CellPadding = UDim2.fromOffset(4, 4)
	presetLayout.Parent = ui.presets

	sb.ready = true
	Log("sandbox pronto — 'help' lista os comandos")
end

local function ShowPresets(names)
	if not ui.presets then return end

	for _, child in ipairs(ui.presets:GetChildren()) do
		if child:IsA("TextButton") then child:Destroy() end
	end

	for _, name in ipairs(names) do
		Button(name, ui.presets, function() Run("preset " .. name) end).Size = UDim2.fromOffset(148, 22)
	end
end

GameAction.OnClientEvent:Connect(function(action, payload)
	if action ~= "sandbox" or type(payload) ~= "table" then return end

	if payload.enabled then BuildUi() end
	if not sb.ready then return end

	if payload.log then Log(payload.log) end
	if payload.presets then ShowPresets(payload.presets) end
	if payload.forward then Run(payload.forward) end
	if payload.closed then
		SetCine(false)
		cam.token += 1
	end
end)

MatchUpdate.OnClientEvent:Connect(function(state)
	sb.snapshot = state

	if state.finisher and state.phase ~= "finished" then
		cam.token += 1
	end
end)

if RunService:IsStudio() then
	task.spawn(function()
		for _ = 1, 8 do
			if sb.ready then return end
			GameAction:FireServer("sandbox", "hello")
			task.wait(1.5)
		end
	end)
end

UserInputService.InputBegan:Connect(function(input, processed)
	if not sb.ready then return end

	if input.KeyCode == Enum.KeyCode.F2 then
		LOCAL.panel()
		return
	end

	if processed or not sb.pick then return end
	if input.UserInputType ~= Enum.UserInputType.MouseButton1
		and input.UserInputType ~= Enum.UserInputType.Touch then return end

	local target = mouse.Target
	if not (target and HexGrid.Exists(target.Name)) then return end

	if ui.input then
		ui.input.Text = ui.input.Text .. (ui.input.Text == "" and "" or " ") .. target.Name
	end
	Log("casa " .. target.Name)
end)

player.CharacterAdded:Connect(function()
	task.wait(1)
	if cine.on then SetCharacterVisible(false) end
end)
