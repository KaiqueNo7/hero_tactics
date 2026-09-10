local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local INTRO_FADE = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local INTRO_AUTO_DISMISS = 22

local GameConfig = require(ReplicatedStorage.Modules.GameConfig)

local MatchUpdate = ReplicatedStorage.Remotes:WaitForChild("MatchUpdate")
local GameAction = ReplicatedStorage.Remotes:WaitForChild("GameAction")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local ui = {
	PANEL = Color3.fromRGB(16, 19, 28),
	CARD = Color3.fromRGB(26, 31, 44),
	GOLD = Color3.fromRGB(255, 214, 120),
	DIM = Color3.fromRGB(96, 102, 116),
	TEXT = Color3.fromRGB(228, 236, 250),
	SOFT = Color3.fromRGB(168, 178, 198),
	GOOD = Color3.fromRGB(120, 220, 150),
	BAD = Color3.fromRGB(235, 105, 105),
}

local function corner(instance, radius)
	local shape = Instance.new("UICorner")
	shape.CornerRadius = UDim.new(0, radius or 8)
	shape.Parent = instance
	return shape
end

local function stroke(instance, color, thickness, transparency)
	local line = Instance.new("UIStroke")
	line.Color = color
	line.Thickness = thickness or 1
	line.Transparency = transparency or 0
	line.Parent = instance
	return line
end

local function label(parent, size, position, text, color, textSize, font)
	local item = Instance.new("TextLabel")
	item.Size = size
	item.Position = position
	item.BackgroundTransparency = 1
	item.Text = text
	item.TextColor3 = color
	item.TextSize = textSize
	item.Font = font or GameConfig.UI_FONT_BODY
	item.TextXAlignment = Enum.TextXAlignment.Left
	item.Parent = parent
	return item
end

local function button(parent, text, color, order)
	local item = Instance.new("TextButton")
	item.Size = UDim2.new(0, 116, 0, 34)
	item.BackgroundColor3 = color
	item.Text = text
	item.TextColor3 = Color3.new(1, 1, 1)
	item.TextSize = 14
	item.Font = Enum.Font.GothamBold
	item.BorderSizePixel = 0
	item.AutoButtonColor = true
	item.LayoutOrder = order
	item.Parent = parent
	corner(item, 8)
	return item
end

local gui = Instance.new("ScreenGui")
gui.Name = "ChallengeGui"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = false
gui.DisplayOrder = 6
gui.Enabled = false
gui.Parent = playerGui

local strip = Instance.new("Frame")
strip.Name = "Objective"
strip.AnchorPoint = Vector2.new(0.5, 0)
strip.Position = UDim2.new(0.5, 0, 0, 10)
strip.Size = UDim2.new(0, 320, 0, 46)
strip.BackgroundColor3 = ui.PANEL
strip.BackgroundTransparency = 0.12
strip.BorderSizePixel = 0
strip.Visible = false
strip.Parent = gui
corner(strip, 10)
stroke(strip, ui.GOLD, 1, 0.6)

local objectiveLabel = label(strip, UDim2.new(1, -74, 0, 18), UDim2.new(0, 12, 0, 6),
	"", ui.TEXT, 14, Enum.Font.GothamBold)

local starRow = label(strip, UDim2.new(0, 60, 0, 18), UDim2.new(1, -68, 0, 6),
	"", ui.GOLD, 16, Enum.Font.GothamBold)
starRow.TextXAlignment = Enum.TextXAlignment.Right

local turnLabel = label(strip, UDim2.new(1, -24, 0, 15), UDim2.new(0, 12, 0, 25),
	"", ui.SOFT, 12)

local controls = Instance.new("Frame")
controls.Name = "Controls"
controls.AnchorPoint = Vector2.new(1, 1)
controls.Position = UDim2.new(1, -16, 1, -104)
controls.Size = UDim2.new(0, 108, 0, 32)
controls.BackgroundTransparency = 1
controls.Visible = false
controls.Parent = gui

local controlsLayout = Instance.new("UIListLayout")
controlsLayout.FillDirection = Enum.FillDirection.Horizontal
controlsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
controlsLayout.Padding = UDim.new(0, 8)
controlsLayout.SortOrder = Enum.SortOrder.LayoutOrder
controlsLayout.Parent = controls

local retryLive = button(controls, "REPETIR", Color3.fromHex("#2450ef"), 1)
retryLive.Size = UDim2.new(0, 104, 0, 32)

local result = Instance.new("Frame")
result.Name = "Result"
result.AnchorPoint = Vector2.new(0.5, 0.5)
result.Position = UDim2.new(0.5, 0, 0.5, 0)
result.Size = UDim2.new(0, 410, 0, 254)
result.BackgroundColor3 = ui.PANEL
result.BorderSizePixel = 0
result.Visible = false
result.Parent = gui
corner(result, 14)
stroke(result, ui.GOLD, 2, 0.35)

local resultTitle = label(result, UDim2.new(1, -32, 0, 26), UDim2.new(0, 16, 0, 16),
	"", ui.GOLD, 22, GameConfig.UI_FONT_DISPLAY)
resultTitle.TextXAlignment = Enum.TextXAlignment.Center

local resultStars = label(result, UDim2.new(1, -32, 0, 40), UDim2.new(0, 16, 0, 44),
	"", ui.GOLD, 34, Enum.Font.GothamBold)
resultStars.TextXAlignment = Enum.TextXAlignment.Center

local resultLine = label(result, UDim2.new(1, -32, 0, 18), UDim2.new(0, 16, 0, 88),
	"", ui.SOFT, 13)
resultLine.TextXAlignment = Enum.TextXAlignment.Center

local starList = Instance.new("Frame")
starList.Position = UDim2.new(0, 22, 0, 112)
starList.Size = UDim2.new(1, -44, 0, 54)
starList.BackgroundTransparency = 1
starList.Parent = result

local starListLayout = Instance.new("UIListLayout")
starListLayout.Padding = UDim.new(0, 3)
starListLayout.SortOrder = Enum.SortOrder.LayoutOrder
starListLayout.Parent = starList

local rewardLine = label(result, UDim2.new(1, -32, 0, 16), UDim2.new(0, 16, 0, 170),
	"", ui.GOOD, 12)
rewardLine.TextXAlignment = Enum.TextXAlignment.Center

local resultButtons = Instance.new("Frame")
resultButtons.AnchorPoint = Vector2.new(0.5, 1)
resultButtons.Position = UDim2.new(0.5, 0, 1, -16)
resultButtons.Size = UDim2.new(1, -32, 0, 34)
resultButtons.BackgroundTransparency = 1
resultButtons.Parent = result

local resultLayout = Instance.new("UIListLayout")
resultLayout.FillDirection = Enum.FillDirection.Horizontal
resultLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
resultLayout.Padding = UDim.new(0, 8)
resultLayout.SortOrder = Enum.SortOrder.LayoutOrder
resultLayout.Parent = resultButtons

local nextButton = button(resultButtons, "PRÓXIMO", Color3.fromRGB(60, 150, 100), 1)
local retryButton = button(resultButtons, "REPETIR", Color3.fromRGB(58, 88, 148), 2)
local exitButton = button(resultButtons, "SAIR", Color3.fromRGB(74, 78, 92), 3)

local intro = Instance.new("ScreenGui")
intro.Name = "ChallengeIntroGui"
intro.ResetOnSpawn = false
intro.IgnoreGuiInset = true
intro.DisplayOrder = 41
intro.Enabled = false
intro.Parent = playerGui

local introCard = Instance.new("Frame")
introCard.AnchorPoint = Vector2.new(0.5, 1)
introCard.Position = UDim2.new(0.5, 0, 1, 40)
introCard.Size = UDim2.new(0, 470, 0, 116)
introCard.BackgroundColor3 = Color3.fromRGB(24, 27, 38)
introCard.BackgroundTransparency = 0.06
introCard.BorderSizePixel = 0
introCard.Parent = intro
corner(introCard, 14)
stroke(introCard, ui.GOLD, 2, 0.15)

local introAccent = Instance.new("Frame")
introAccent.Size = UDim2.new(0, 5, 1, -24)
introAccent.Position = UDim2.new(0, 12, 0, 12)
introAccent.BackgroundColor3 = ui.GOLD
introAccent.BorderSizePixel = 0
introAccent.Parent = introCard
corner(introAccent, 99)

local introTitle = label(introCard, UDim2.new(1, -120, 0, 22), UDim2.new(0, 30, 0, 10),
	"", ui.GOLD, 17, Enum.Font.GothamBlack)

local introObjective = label(introCard, UDim2.new(1, -140, 0, 16), UDim2.new(0, 30, 0, 32),
	"", Color3.fromRGB(150, 205, 250), 13, Enum.Font.GothamBold)

local introText = label(introCard, UDim2.new(1, -150, 0, 32), UDim2.new(0, 30, 0, 50),
	"", Color3.fromRGB(214, 222, 238), 13)
introText.TextWrapped = true
introText.TextYAlignment = Enum.TextYAlignment.Top

local introStars = label(introCard, UDim2.new(1, -150, 0, 16), UDim2.new(0, 30, 1, -26),
	"", ui.SOFT, 11)

local introOk = button(introCard, "COMEÇAR", Color3.fromRGB(60, 150, 100), 1)
introOk.AnchorPoint = Vector2.new(1, 1)
introOk.Position = UDim2.new(1, -14, 1, -12)
introOk.Size = UDim2.new(0, 104, 0, 28)

local introToken = 0
local introShownFor = nil

local function hideIntro()
	if not intro.Enabled then return end
	introToken += 1
	local token = introToken

	TweenService:Create(introCard, INTRO_FADE, { Position = UDim2.new(0.5, 0, 1, 40) }):Play()
	task.delay(INTRO_FADE.Time, function()
		if introToken == token then intro.Enabled = false end
	end)
end

local function showIntro(challenge)
	local key = ("%d:%d"):format(challenge.heroId, challenge.index)
	if introShownFor == key then return end
	introShownFor = key
	introToken += 1
	local token = introToken

	introTitle.Text = challenge.name:upper()
	introObjective.Text = challenge.objective
	introText.Text = challenge.concept

	local extras = {}
	for _, star in ipairs(challenge.stars) do table.insert(extras, "★ " .. star.text) end
	introStars.Text = table.concat(extras, "     ")

	intro.Enabled = true
	introCard.Position = UDim2.new(0.5, 0, 1, 40)
	TweenService:Create(introCard, INTRO_FADE, { Position = UDim2.new(0.5, 0, 1, -18) }):Play()

	task.delay(INTRO_AUTO_DISMISS, function()
		if introToken == token then hideIntro() end
	end)
end

introOk.MouseButton1Click:Connect(hideIntro)

local function send(command)
	GameAction:FireServer("challenge", command)
end

retryLive.MouseButton1Click:Connect(function() send("restart") end)
retryButton.MouseButton1Click:Connect(function() send("restart") end)
exitButton.MouseButton1Click:Connect(function() send("exit") end)
nextButton.MouseButton1Click:Connect(function() send("next") end)

local function turnos(n)
	return n == 1 and "1 turno" or ("%d turnos"):format(n)
end

local function starText(count, total)
	return string.rep("★", count) .. string.rep("☆", math.max(0, total - count))
end

local function renderStrip(challenge)
	objectiveLabel.Text = challenge.objective

	local alive = 1
	for _, star in ipairs(challenge.stars) do
		if star.state ~= "failed" then alive += 1 end
	end
	starRow.Text = starText(alive, #challenge.stars + 1)
	starRow.TextColor3 = alive == #challenge.stars + 1 and ui.GOLD or ui.DIM

	local left = math.max(0, (challenge.maxTurns or 0) - (challenge.turn or 0) + 1)
	turnLabel.Text = ("%s  ·  %s restantes de %d")
		:format(challenge.name, turnos(left), challenge.maxTurns or 0)
end

local function renderStarList(challenge)
	for _, child in ipairs(starList:GetChildren()) do
		if child:IsA("TextLabel") then child:Destroy() end
	end

	local won = challenge.outcome == "win"
	local rows = { { text = challenge.objective, ok = won } }
	for _, star in ipairs(challenge.stars) do
		table.insert(rows, { text = star.text, ok = won and star.state == "done" })
	end

	for index, row in ipairs(rows) do
		local item = label(starList, UDim2.new(1, 0, 0, 16), UDim2.new(),
			("%s  %s"):format(row.ok and "★" or "☆", row.text),
			row.ok and ui.GOLD or ui.DIM, 12)
		item.LayoutOrder = index
	end
end

local function renderResult(challenge)
	local won = challenge.outcome == "win"

	resultTitle.Text = won and "DESAFIO CONCLUÍDO" or "NÃO FOI DESSA VEZ"
	resultTitle.TextColor3 = won and ui.GOLD or ui.BAD

	resultStars.Text = starText(won and challenge.earned or 0, #challenge.stars + 1)
	resultStars.TextColor3 = won and ui.GOLD or ui.DIM

	if won then
		local best = math.max(challenge.best or 0, challenge.earned or 0)
		local bestTurns = challenge.bestTurns or 0
		resultLine.Text = bestTurns > 0
			and ("Você venceu em %s  ·  sua melhor marca: %d★ em %s")
				:format(turnos(challenge.turn or 0), best, turnos(bestTurns))
			or ("Você venceu em %s"):format(turnos(challenge.turn or 0))
	else
		resultLine.Text = challenge.reason or "Tente de novo."
	end

	renderStarList(challenge)

	rewardLine.Text = (challenge.xp or 0) > 0 and ("+%d XP"):format(challenge.xp) or ""
	nextButton.Visible = won and challenge.hasNext == true
end

MatchUpdate.OnClientEvent:Connect(function(state)
	local challenge = state and state.challenge

	if not challenge then
		gui.Enabled = false
		strip.Visible = false
		controls.Visible = false
		result.Visible = false
		hideIntro()
		introShownFor = nil
		return
	end

	gui.Enabled = true

	if state.phase == "finished" then
		strip.Visible = false
		controls.Visible = false
		result.Visible = true
		hideIntro()
		renderResult(challenge)
		return
	end

	result.Visible = false
	strip.Visible = state.phase == "battle"
	controls.Visible = state.phase == "battle"
	if strip.Visible then
		renderStrip(challenge)
		showIntro(challenge)
	end
end)

GameAction.OnClientEvent:Connect(function(action, payload)
	if action ~= "challengeRefused" then return end
	warn("Desafio recusado: " .. tostring(payload))
end)
