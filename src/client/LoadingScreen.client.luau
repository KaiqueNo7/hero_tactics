--[[
	LoadingScreen.client.lua
	LocalScript — ReplicatedFirst

	Tela de entrada: segura o jogador numa cortina opaca até o cenário, os
	sprites, os sons e a iluminação estarem realmente prontos.

	Por que em ReplicatedFirst: é a única pasta que roda ANTES do resto replicar.
	Um script em StarterPlayerScripts só acorda com o mundo já montado — tarde
	demais pra esconder a taverna aparecendo pedaço por pedaço.

	As três esperas, em ordem:
	  1. game:IsLoaded()   — a árvore do jogo chegou inteira
	  2. Lighting pronta   — o atributo que o LightingSetup marca no servidor;
	                         sem ele o jogador entra a tempo de ver a luz mudar
	  3. PreloadAsync      — texturas, malhas e sons já em memória, pra não
	                         aparecer sprite branco no primeiro frame

	Nada disso pode travar o jogo pra sempre: cada etapa tem prazo, e no fim do
	HARD_TIMEOUT a cortina sobe mesmo que algo não tenha respondido.
]]

local ContentProvider = game:GetService("ContentProvider")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

-- Mesma string de ServerScriptService.Modules.LightingSetup.READY_ATTRIBUTE.
-- Repetida (e não exigida) porque o cliente não enxerga ServerScriptService.
local LIGHTING_READY_ATTRIBUTE = "HeroTacticsLightingReady"

local HARD_TIMEOUT = 25 -- teto absoluto: passou disso, entra do jeito que está
local LIGHTING_TIMEOUT = 8 -- servidor pode estar sem o script; não vale travar
local MIN_SHOW_TIME = 1.0 -- evita o "pisca" de uma cortina que some em 2 frames
local FADE_TIME = 0.45

-- Preload de tudo que existe no Workspace seria caro num lobby com centenas de
-- peças. Este teto pega o que importa (o cenário perto) sem virar espera eterna.
local MAX_ASSETS = 700

local startedAt = os.clock()

ReplicatedFirst:RemoveDefaultLoadingScreen()

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ===== CORTINA =====
local gui = Instance.new("ScreenGui")
gui.Name = "LoadingScreen"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 1000 -- por cima de absolutamente tudo
gui.Parent = playerGui

local backdrop = Instance.new("Frame")
backdrop.Size = UDim2.fromScale(1, 1)
backdrop.BackgroundColor3 = Color3.fromRGB(9, 10, 15)
backdrop.BorderSizePixel = 0
backdrop.Parent = gui

-- leve degradê pra cortina não ser um retângulo chapado
local backdropGradient = Instance.new("UIGradient")
backdropGradient.Rotation = 90
backdropGradient.Color = ColorSequence.new(
	Color3.fromRGB(22, 24, 34),
	Color3.fromRGB(7, 8, 12)
)
backdropGradient.Parent = backdrop

local panel = Instance.new("Frame")
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.5)
panel.Size = UDim2.new(0, 520, 0, 200)
panel.BackgroundTransparency = 1
panel.Parent = backdrop

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 58)
title.BackgroundTransparency = 1
title.Text = "TÁTICAS DE HERÓI"
title.TextColor3 = Color3.fromRGB(255, 226, 150)
title.TextStrokeTransparency = 0.6
title.TextScaled = true
title.Font = Enum.Font.GothamBlack
title.Parent = panel

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, 0, 0, 28)
status.Position = UDim2.new(0, 0, 0, 74)
status.BackgroundTransparency = 1
status.Text = "Conectando..."
status.TextColor3 = Color3.fromRGB(210, 220, 238)
status.TextScaled = true
status.Font = Enum.Font.GothamBold
status.Parent = panel

local track = Instance.new("Frame")
track.AnchorPoint = Vector2.new(0.5, 0)
track.Position = UDim2.new(0.5, 0, 0, 116)
track.Size = UDim2.new(0, 340, 0, 6)
track.BackgroundColor3 = Color3.fromRGB(38, 44, 60)
track.BorderSizePixel = 0
track.ClipsDescendants = true
track.Parent = panel

local trackCorner = Instance.new("UICorner")
trackCorner.CornerRadius = UDim.new(1, 0)
trackCorner.Parent = track

local fill = Instance.new("Frame")
fill.Size = UDim2.new(0, 0, 1, 0)
fill.BackgroundColor3 = Color3.fromRGB(120, 180, 255)
fill.BorderSizePixel = 0
fill.Parent = track

local fillCorner = Instance.new("UICorner")
fillCorner.CornerRadius = UDim.new(1, 0)
fillCorner.Parent = fill

local percent = Instance.new("TextLabel")
percent.Size = UDim2.new(1, 0, 0, 20)
percent.Position = UDim2.new(0, 0, 0, 132)
percent.BackgroundTransparency = 1
percent.Text = "0%"
percent.TextColor3 = Color3.fromRGB(140, 152, 176)
percent.TextScaled = true
percent.Font = Enum.Font.GothamBold
percent.Parent = panel

local hint = Instance.new("TextLabel")
hint.Size = UDim2.new(1, 0, 0, 20)
hint.Position = UDim2.new(0, 0, 0, 164)
hint.BackgroundTransparency = 1
hint.Text = "Dica: cada herói só pode ser escolhido uma vez por partida."
hint.TextColor3 = Color3.fromRGB(120, 132, 155)
hint.TextSize = 14
hint.Font = Enum.Font.SourceSansItalic
hint.Parent = panel

-- ===== PROGRESSO =====
-- A barra anda por tween pra nunca voltar atrás nem pular: o valor bruto do
-- preload sobe aos trancos, e ver a barra saltar dá impressão de travamento.
local shown = 0

local function setProgress(value, text)
	value = math.clamp(value, 0, 1)
	if value > shown then
		shown = value
		TweenService:Create(fill, TweenInfo.new(0.25), { Size = UDim2.fromScale(value, 1) }):Play()
		percent.Text = ("%d%%"):format(math.floor(value * 100))
	end
	if text then status.Text = text end
end

-- ===== COLETA DE ASSETS =====
local function isPreloadable(instance)
	return instance:IsA("Decal")
		or instance:IsA("Texture")
		or instance:IsA("MeshPart")
		or instance:IsA("SpecialMesh")
		or instance:IsA("Sky")
		or instance:IsA("ImageLabel")
		or instance:IsA("ImageButton")
		or instance:IsA("Sound")
		or instance:IsA("ParticleEmitter")
		or instance:IsA("SurfaceAppearance")
end

local function collect(root, into)
	if not root then return end
	for _, descendant in ipairs(root:GetDescendants()) do
		if #into >= MAX_ASSETS then return end
		if isPreloadable(descendant) then
			table.insert(into, descendant)
		end
	end
end

-- ===== ETAPAS =====
local function timeLeft()
	return HARD_TIMEOUT - (os.clock() - startedAt)
end

setProgress(0.05, "Conectando...")

-- 1) árvore do jogo
if not game:IsLoaded() then
	local loaded = false
	task.spawn(function()
		game.Loaded:Wait()
		loaded = true
	end)
	while not loaded and timeLeft() > 0 do
		setProgress(math.min(0.2, shown + 0.01), "Baixando o jogo...")
		task.wait(0.1)
	end
end

setProgress(0.25, "Preparando o cenário...")

-- 2) iluminação vinda do servidor
local waitedForLight = 0
while Lighting:GetAttribute(LIGHTING_READY_ATTRIBUTE) ~= true
	and waitedForLight < LIGHTING_TIMEOUT
	and timeLeft() > 0 do
	task.wait(0.1)
	waitedForLight += 0.1
	setProgress(math.min(0.38, shown + 0.004), "Acendendo a taverna...")
end

if Lighting:GetAttribute(LIGHTING_READY_ATTRIBUTE) ~= true then
	warn("LoadingScreen: iluminação não confirmou em " .. LIGHTING_TIMEOUT .. "s; entrando assim mesmo.")
end

setProgress(0.4, "Carregando texturas...")

-- 3) preload de verdade
local assets = {}

-- as folhas de sprite entram por id: elas só viram ImageLabel na hora que a
-- partida começa, então não estariam em lugar nenhum da árvore ainda
local heroDataModule = ReplicatedStorage:FindFirstChild("Modules")
heroDataModule = heroDataModule and heroDataModule:FindFirstChild("HeroData")
if heroDataModule then
	local ok, HeroData = pcall(require, heroDataModule)
	if ok then
		local ids = { HeroData.GetSpriteId(), HeroData.GetPoisonSpriteId() }

		-- herói novo não entra na folha: cada um traz o próprio asset, e sem
		-- preload ele aparece branco no primeiro quadro da partida
		for _, data in ipairs(HeroData.CATALOG) do
			if data.sprite then table.insert(ids, HeroData.GetSpriteId(data)) end
		end

		for _, id in ipairs(ids) do
			if id then table.insert(assets, id) end
		end
	end
end

collect(Lighting, assets)
collect(ReplicatedStorage:FindFirstChild("Sounds"), assets)
collect(ReplicatedStorage:FindFirstChild("HexTile"), assets)
collect(ReplicatedStorage:FindFirstChild("BotDummyTemplate"), assets)
collect(Workspace, assets)

local total = #assets
local done = 0
local preloadFinished = false

task.spawn(function()
	local ok, err = pcall(function()
		ContentProvider:PreloadAsync(assets, function()
			done += 1
		end)
	end)
	if not ok then
		warn("LoadingScreen: PreloadAsync falhou: " .. tostring(err))
	end
	preloadFinished = true
end)

-- O callback do PreloadAsync dispara uma vez por CONTEÚDO, não por instância:
-- uma MeshPart com textura conta duas. Sem o teto, a contagem passava do total
-- e a tela mostrava "38/34".
local function loaded()
	return math.min(done, total)
end

while not preloadFinished and timeLeft() > 0 do
	local ratio = total > 0 and (loaded() / total) or 1
	setProgress(0.4 + ratio * 0.58, ("Carregando texturas...  %d/%d"):format(loaded(), total))
	task.wait(0.08)
end

if not preloadFinished then
	warn(("LoadingScreen: preload no prazo máximo (%d/%d); entrando assim mesmo."):format(loaded(), total))
end

-- ===== SAÍDA =====
setProgress(1, "Pronto!")

-- um frame renderizado com tudo em memória antes de revelar: é o que evita o
-- lampejo de textura branca logo depois do fade
RunService.RenderStepped:Wait()

local elapsed = os.clock() - startedAt
if elapsed < MIN_SHOW_TIME then
	task.wait(MIN_SHOW_TIME - elapsed)
end

local info = TweenInfo.new(FADE_TIME)
TweenService:Create(backdrop, info, { BackgroundTransparency = 1 }):Play()
for _, label in ipairs({ title, status, percent, hint }) do
	TweenService:Create(label, info, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
end
TweenService:Create(track, info, { BackgroundTransparency = 1 }):Play()
TweenService:Create(fill, info, { BackgroundTransparency = 1 }):Play()

task.wait(FADE_TIME)
gui:Destroy()

print(("LoadingScreen: entrou em %.1fs (%d/%d assets)."):format(os.clock() - startedAt, loaded(), total))
