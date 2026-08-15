--[[
	BattleClient.client.lua
	LocalScript — StarterPlayer/StarterPlayerScripts
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")

local HexGrid = require(ReplicatedStorage.Modules.HexGrid)
local HeroData = require(ReplicatedStorage.Modules.HeroData)
local MatchUpdate = ReplicatedStorage.Remotes:WaitForChild("MatchUpdate")
local GameAction = ReplicatedStorage.Remotes:WaitForChild("GameAction")

local player = Players.LocalPlayer
local mouse = player:GetMouse()

local MOVE_COLOR = Color3.fromRGB(110, 220, 130)
local ATTACK_COLOR = Color3.fromRGB(230, 90, 90)

-- cor base caso o attribute BaseColor não exista (defensivo)
local COLOR_A = Color3.fromRGB(120, 170, 220)
local COLOR_B = Color3.fromRGB(90, 130, 180)

local function fallbackColor(tile)
	local col = string.byte(tile.Name, 1) - string.byte("A", 1)
	return (col % 2 == 0) and COLOR_A or COLOR_B
end

local state = nil
local selectedUid = nil
local moveTargets, attackTargets, savedColors = {}, {}, {}
local secondsLeft = nil
local wasMyTurn = false
local resultPlayed = false

local function PlayUiSound(name)
	local template = ReplicatedStorage.Sounds:FindFirstChild(name)
	if not template then return end
	local sound = template:Clone()
	sound.Parent = SoundService
	sound:Play()
	Debris:AddItem(sound, 3)
end

-- ===== UI =====
local gui = Instance.new("ScreenGui")
gui.Name = "BattleGui"
gui.ResetOnSpawn = false
gui.Enabled = false
gui.IgnoreGuiInset = true
gui.Parent = player:WaitForChild("PlayerGui")

-- ===== INDICADOR DE TURNO (centralizado) =====
local turnPanel = Instance.new("Frame")
turnPanel.AnchorPoint = Vector2.new(0.5, 0)
turnPanel.Size = UDim2.new(0, 220, 0, 40)
turnPanel.Position = UDim2.new(0.5, 0, 0, 10)
turnPanel.BackgroundColor3 = Color3.fromRGB(16, 18, 26)
turnPanel.BackgroundTransparency = 0.2
turnPanel.BorderSizePixel = 0
turnPanel.Parent = gui

local turnCorner = Instance.new("UICorner")
turnCorner.CornerRadius = UDim.new(0, 8)
turnCorner.Parent = turnPanel

local turnLabel = Instance.new("TextLabel")
turnLabel.Size = UDim2.fromScale(1, 1)
turnLabel.BackgroundTransparency = 1
turnLabel.TextColor3 = Color3.new(1, 1, 1)
turnLabel.TextXAlignment = Enum.TextXAlignment.Center
turnLabel.TextScaled = true
turnLabel.Font = Enum.Font.GothamBold
turnLabel.Parent = turnPanel

-- ===== TIMER (só aparece com <10s, canto superior direito) =====
local timerLabel = Instance.new("TextLabel")
timerLabel.AnchorPoint = Vector2.new(1, 0)
timerLabel.Size = UDim2.new(0, 70, 0, 28)
timerLabel.Position = UDim2.new(1, 0, 0, 20)
timerLabel.BackgroundTransparency = 1
timerLabel.TextColor3 = Color3.fromRGB(255, 110, 110)
timerLabel.TextStrokeTransparency = 0.4
timerLabel.TextScaled = true
timerLabel.Font = Enum.Font.GothamBlack
timerLabel.Text = ""
timerLabel.Visible = false
timerLabel.Parent = gui

-- ===== "SUA VEZ" (flash centralizado na tela) =====
local turnFlashLabel = Instance.new("TextLabel")
turnFlashLabel.AnchorPoint = Vector2.new(0.5, 0.5)
turnFlashLabel.Size = UDim2.new(0, 400, 0, 70)
turnFlashLabel.Position = UDim2.new(0.5, 0, 0.4, 0)
turnFlashLabel.BackgroundTransparency = 1
turnFlashLabel.TextColor3 = Color3.fromRGB(255, 235, 150)
turnFlashLabel.TextStrokeTransparency = 1
turnFlashLabel.TextScaled = true
turnFlashLabel.Font = Enum.Font.GothamBlack
turnFlashLabel.Text = "Sua vez!"
turnFlashLabel.TextTransparency = 1
turnFlashLabel.Parent = gui

local messageLabel = Instance.new("TextLabel")
messageLabel.Size = UDim2.new(0, 460, 0, 30)
messageLabel.Position = UDim2.new(0.5, -230, 0, 58)
messageLabel.BackgroundTransparency = 1
messageLabel.TextColor3 = Color3.fromRGB(255, 225, 130)
messageLabel.TextStrokeTransparency = 0.35
messageLabel.TextScaled = true
messageLabel.Font = Enum.Font.GothamBold
messageLabel.Text = ""
messageLabel.TextTransparency = 1
messageLabel.Parent = gui

-- ===== BOTÃO DE PASSAR TURNO (hexágono com check) =====
local endTurnButton = Instance.new("ImageButton")
endTurnButton.Size = UDim2.new(0, 74, 0, 74)
endTurnButton.Position = UDim2.new(1, -100, 1, -100)
endTurnButton.BackgroundTransparency = 1
endTurnButton.Image = "rbxassetid://87779944037512"
endTurnButton.ImageColor3 = Color3.fromRGB(60, 90, 150)
endTurnButton.Parent = gui

local endTurnCheck = Instance.new("TextLabel")
endTurnCheck.Size = UDim2.fromScale(1, 1)
endTurnCheck.BackgroundTransparency = 1
endTurnCheck.Text = "✓"
endTurnCheck.TextColor3 = Color3.new(1, 1, 1)
endTurnCheck.TextStrokeTransparency = 0.5
endTurnCheck.TextScaled = true
endTurnCheck.Font = Enum.Font.GothamBlack
endTurnCheck.Parent = endTurnButton

endTurnButton.MouseButton1Click:Connect(function()
	if not (state and state.isMyTurn) then return end
	GameAction:FireServer("endTurn")
end)

-- ===== PAINEL DE DETALHE DO HERÓI SELECIONADO =====
local detailPanel = Instance.new("Frame")
detailPanel.Size = UDim2.new(0, 210, 0, 96)
detailPanel.Position = UDim2.new(0, 16, 1, -112)
detailPanel.BackgroundColor3 = Color3.fromRGB(16, 18, 26)
detailPanel.BackgroundTransparency = 0.15
detailPanel.BorderSizePixel = 0
detailPanel.Visible = false
detailPanel.Parent = gui

local detailCorner = Instance.new("UICorner")
detailCorner.CornerRadius = UDim.new(0, 8)
detailCorner.Parent = detailPanel

local detailName = Instance.new("TextLabel")
detailName.Size = UDim2.new(1, -16, 0, 24)
detailName.Position = UDim2.new(0, 8, 0, 6)
detailName.BackgroundTransparency = 1
detailName.TextColor3 = Color3.new(1, 1, 1)
detailName.TextXAlignment = Enum.TextXAlignment.Left
detailName.TextScaled = true
detailName.Font = Enum.Font.GothamBold
detailName.Parent = detailPanel

local detailStats = Instance.new("TextLabel")
detailStats.Size = UDim2.new(1, -16, 0, 20)
detailStats.Position = UDim2.new(0, 8, 0, 32)
detailStats.BackgroundTransparency = 1
detailStats.TextColor3 = Color3.fromRGB(210, 220, 235)
detailStats.TextXAlignment = Enum.TextXAlignment.Left
detailStats.TextScaled = true
detailStats.Font = Enum.Font.Gotham
detailStats.Parent = detailPanel

local detailSkills = Instance.new("TextLabel")
detailSkills.Size = UDim2.new(1, -16, 0, 34)
detailSkills.Position = UDim2.new(0, 8, 0, 54)
detailSkills.BackgroundTransparency = 1
detailSkills.TextColor3 = Color3.fromRGB(180, 215, 255)
detailSkills.TextXAlignment = Enum.TextXAlignment.Left
detailSkills.TextYAlignment = Enum.TextYAlignment.Top
detailSkills.TextWrapped = true
detailSkills.TextSize = 13
detailSkills.Font = Enum.Font.Gotham
detailSkills.Parent = detailPanel

local function showDetail(hero)
	if not hero then
		detailPanel.Visible = false
		return
	end

	local data = HeroData.GetById(hero.dataId)
	detailPanel.Visible = true
	detailName.Text = hero.name
	detailStats.Text = ("%d ATK   %d/%d HP   %s"):format(
		hero.attack, math.max(hero.currentHp, 0), hero.maxHp, hero.ability or "-")

	local names = {}
	for _, key in ipairs(data and data.abilities or {}) do
		local info = HeroData.SKILL_INFO[key]
		table.insert(names, info and info.name or key)
	end
	detailSkills.Text = table.concat(names, " • ")
end

-- ===== PAINEL DE FIM DE PARTIDA =====
local resultPanel = Instance.new("Frame")
resultPanel.Size = UDim2.new(0, 320, 0, 220)
resultPanel.Position = UDim2.new(0.5, -160, 0.5, -110)
resultPanel.BackgroundColor3 = Color3.fromRGB(16, 18, 26)
resultPanel.BackgroundTransparency = 0.1
resultPanel.BorderSizePixel = 0
resultPanel.Visible = false
resultPanel.Parent = gui

local resultCorner = Instance.new("UICorner")
resultCorner.CornerRadius = UDim.new(0, 12)
resultCorner.Parent = resultPanel

local resultLabel = Instance.new("TextLabel")
resultLabel.Size = UDim2.new(1, -20, 0, 60)
resultLabel.Position = UDim2.new(0, 10, 0, 16)
resultLabel.BackgroundTransparency = 1
resultLabel.TextScaled = true
resultLabel.Font = Enum.Font.GothamBold
resultLabel.Parent = resultPanel

local replayButton = Instance.new("TextButton")
replayButton.Size = UDim2.new(1, -60, 0, 46)
replayButton.Position = UDim2.new(0, 30, 1, -122)
replayButton.BackgroundColor3 = Color3.fromRGB(70, 150, 90)
replayButton.TextColor3 = Color3.new(1, 1, 1)
replayButton.Font = Enum.Font.GothamBold
replayButton.TextSize = 20
replayButton.Text = "Jogar novamente"
replayButton.BorderSizePixel = 0
replayButton.Parent = resultPanel

local replayCorner = Instance.new("UICorner")
replayCorner.CornerRadius = UDim.new(0, 8)
replayCorner.Parent = replayButton

local lobbyButton = Instance.new("TextButton")
lobbyButton.Size = UDim2.new(1, -60, 0, 46)
lobbyButton.Position = UDim2.new(0, 30, 1, -66)
lobbyButton.BackgroundColor3 = Color3.fromRGB(60, 70, 90)
lobbyButton.TextColor3 = Color3.new(1, 1, 1)
lobbyButton.Font = Enum.Font.GothamBold
lobbyButton.TextSize = 20
lobbyButton.Text = "Voltar pro lobby"
lobbyButton.BorderSizePixel = 0
lobbyButton.Parent = resultPanel

local lobbyCorner = Instance.new("UICorner")
lobbyCorner.CornerRadius = UDim.new(0, 8)
lobbyCorner.Parent = lobbyButton

replayButton.MouseButton1Click:Connect(function()
	GameAction:FireServer("replay")
end)

lobbyButton.MouseButton1Click:Connect(function()
	GameAction:FireServer("leaveMatch")
end)

-- ===== DESTAQUES =====
local function clearHighlights()
	for part in pairs(savedColors) do
		if part.Parent then
			part.Color = part:GetAttribute("BaseColor") or fallbackColor(part)
		end
	end
	savedColors, moveTargets, attackTargets = {}, {}, {}
end

local function paint(hexId, color)
	local board = Workspace:FindFirstChild("Board")
	local tile = board and board:FindFirstChild(hexId)
	if tile and tile:IsA("BasePart") then
		if savedColors[tile] == nil then savedColors[tile] = true end
		tile.Color = color
	end
end

local function heroByUid(uid)
	for _, hero in ipairs(state.heroes) do
		if hero.uid == uid then return hero end
	end
	return nil
end

local function selectHero(uid)
	clearHighlights()

	local hero = heroByUid(uid)
	if not hero or not hero.isMine or not hero.isAlive then
		selectedUid = nil
		showDetail(nil)
		return
	end

	-- mesma corrida da zona de largada: nos primeiros frames o Board pode
	-- ainda não ter sido replicado e o paint falharia calado
	if not Workspace:FindFirstChild("Board") then
		task.delay(0.15, function()
			if selectedUid == uid then selectHero(uid) end
		end)
	end

	selectedUid = uid

	local blocked, enemyAt = {}, {}
	for _, other in ipairs(state.heroes) do
		blocked[other.position] = true
		if other.isAlive and not other.isMine then
			enemyAt[other.position] = other.uid
		end
	end

	local isFree = function(hexId) return not blocked[hexId] end

	if not hero.hasMoved and not hero.hasAttacked then
		for hexId in pairs(HexGrid.ComputeReach(hero.position, hero.moveRange, isFree)) do
			if isFree(hexId) then
				moveTargets[hexId] = true
				paint(hexId, MOVE_COLOR)
			end
		end
	end

	if not hero.hasAttacked then
		for hexId in pairs(HexGrid.ComputeReach(hero.position, hero.attackRange, isFree)) do
			if enemyAt[hexId] then
				attackTargets[hexId] = enemyAt[hexId]
				moveTargets[hexId] = nil
				paint(hexId, ATTACK_COLOR)
			end
		end
	end

	showDetail(hero)
end

-- ===== CLIQUES =====
mouse.Button1Down:Connect(function()
	if not state or state.phase ~= "battle" or not state.isMyTurn then return end

	local target = mouse.Target
	if not target then return end

	local heroUid = target:GetAttribute("HeroUid")
	local hexId = target:GetAttribute("HexId")

	if heroUid then
		local hero = heroByUid(heroUid)
		if hero and hero.isMine then
			local newUid = heroUid == selectedUid and "" or heroUid
			if newUid ~= "" then PlayUiSound("HeroSelectBattle") end
			selectHero(newUid)
		elseif selectedUid and hero and attackTargets[hero.position] then
			GameAction:FireServer("attack", selectedUid, hero.uid)
		end
		return
	end

	if hexId and selectedUid then
		if attackTargets[hexId] then
			GameAction:FireServer("attack", selectedUid, attackTargets[hexId])
		elseif moveTargets[hexId] then
			GameAction:FireServer("move", selectedUid, hexId)
		end
	end
end)

-- ===== FILA DE MENSAGENS (uma de cada vez, tipo tooltip) =====
local messageQueue = {}
local messageBusy = false

local function pumpMessages()
	if messageBusy then return end

	local text = table.remove(messageQueue, 1)
	if not text then return end

	messageBusy = true
	messageLabel.Text = text
	messageLabel.TextTransparency = 1
	TweenService:Create(messageLabel, TweenInfo.new(0.18), { TextTransparency = 0 }):Play()

	task.delay(2.0, function()
		TweenService:Create(messageLabel, TweenInfo.new(0.3), { TextTransparency = 1 }):Play()
		task.wait(0.35)
		messageBusy = false
		pumpMessages()
	end)
end

local function queueMessage(text)
	if not text or text == "" then return end
	table.insert(messageQueue, text)
	pumpMessages()
end

-- ===== CRONÔMETRO LOCAL =====
RunService.Heartbeat:Connect(function(dt)
	if secondsLeft then
		secondsLeft = math.max(0, secondsLeft - dt)
		timerLabel.Visible = secondsLeft <= 10
		if secondsLeft <= 10 then
			timerLabel.Text = ("%d"):format(math.ceil(secondsLeft))
		end
	end
end)

-- ===== ESTADO =====
MatchUpdate.OnClientEvent:Connect(function(newState)
	state = newState

	if state.message then
		queueMessage(state.message)
	end

	if state.phase == "finished" then
		gui.Enabled = true
		turnPanel.Visible = false
		timerLabel.Visible = false
		endTurnButton.Visible = false
		detailPanel.Visible = false
		resultPanel.Visible = true
		secondsLeft = nil
		wasMyTurn = false

		-- o servidor já manda o resultado do ponto de vista de quem recebe
		if state.winner == "draw" then
			resultLabel.Text = "Empate"
			resultLabel.TextColor3 = Color3.fromRGB(215, 215, 225)
		else
			resultLabel.Text = state.winner == "win" and "Vitória!" or "Derrota"
			resultLabel.TextColor3 = state.winner == "win"
				and Color3.fromRGB(130, 230, 150) or Color3.fromRGB(230, 120, 120)
		end

		-- o servidor manda o estado final uma vez, mas guardamos mesmo assim
		-- pra revanche não empilhar dois toques
		if not resultPlayed then
			resultPlayed = true
			PlayUiSound(state.winner == "win" and "Victory" or "Defeat")
		end

		clearHighlights()
		selectedUid = nil
		return
	end

	if state.phase ~= "battle" then
		gui.Enabled = false
		clearHighlights()
		selectedUid = nil
		showDetail(nil)
		return
	end

	gui.Enabled = true
	turnPanel.Visible = true
	resultPanel.Visible = false
	resultPlayed = false
	endTurnButton.Visible = true
	endTurnButton.Active = state.isMyTurn
	endTurnButton.ImageColor3 = state.isMyTurn
		and Color3.fromRGB(60, 90, 150) or Color3.fromRGB(65, 65, 72)
	endTurnCheck.TextTransparency = state.isMyTurn and 0 or 0.5

	turnLabel.Text = ("Turno %d%s"):format(
		state.turnNumber,
		state.suddenDeath and "  ☠" or ""
	)
	turnLabel.TextColor3 = state.suddenDeath
		and Color3.fromRGB(255, 140, 140) or Color3.new(1, 1, 1)

	if state.isMyTurn and not wasMyTurn then
		turnFlashLabel.TextTransparency = 1
		turnFlashLabel.TextStrokeTransparency = 1
		TweenService:Create(turnFlashLabel, TweenInfo.new(0.2), {
			TextTransparency = 0, TextStrokeTransparency = 0.3,
		}):Play()
		task.delay(1.1, function()
			TweenService:Create(turnFlashLabel, TweenInfo.new(0.4), {
				TextTransparency = 1, TextStrokeTransparency = 1,
			}):Play()
		end)
	end
	wasMyTurn = state.isMyTurn

	secondsLeft = state.turnSecondsLeft
	if not secondsLeft then timerLabel.Visible = false end

	local previous = selectedUid
	clearHighlights()
	selectedUid = nil

	if state.isMyTurn and previous then
		local hero = heroByUid(previous)
		if hero and hero.isAlive then
			selectHero(previous)
		end
	else
		showDetail(nil)
	end
end)
