--[[
	HeroView.lua
	ModuleScript — ServerScriptService/Modules/HeroView

	Toda a apresentação dos heróis. O MatchManager diz o que aconteceu;
	como isso aparece é problema daqui.

	Texto flutuante agora é uma FILA por herói: uma mensagem de cada vez,
	como tooltip de navegador, em vez de várias empilhadas no mesmo ponto.
	Cada tipo (dano, cura, buff) e cada skill tem sua própria identidade.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")
local SoundService = game:GetService("SoundService")

local HexGrid = require(ReplicatedStorage.Modules.HexGrid)
local HeroData = require(ReplicatedStorage.Modules.HeroData)

local Sounds = ReplicatedStorage:WaitForChild("Sounds")

local HeroView = {}

local SPRITE_SHEET_ID = HeroData.GetSpriteId()
local SPRITES_ENABLED = SPRITE_SHEET_ID ~= nil

if SPRITES_ENABLED then
	print("HeroView: spritesheet = " .. SPRITE_SHEET_ID)
else
	warn("HeroView: sem spritesheet — usando cilindros como placeholder.")
end

-- ===== AJUSTE FINO =====
local SPRITE_WIDTH = 4.2
local TILE_TOP_Y = 0.5
local MOVE_STEP_TIME = 0.22
local BOT_ID = "BOT"

local RING_SCALE = 0.64
local RING_THICKNESS = 0.32
local RING_HEIGHT = 0.08

local TEAM_COLOR_PLAYER_1 = Color3.fromRGB(70, 150, 255)
local TEAM_COLOR_PLAYER_2 = Color3.fromRGB(230, 70, 70)

local SPRITE_HEIGHT = SPRITE_WIDTH * (HeroData.FRAME_HEIGHT / HeroData.FRAME_WIDTH)
local ANCHOR_LIFT = SPRITE_HEIGHT * 0.4

-- ===== ESTILOS DE TEXTO FLUTUANTE =====
local BUBBLE_LIFETIME = 0.95
local BUBBLE_GAP = 0.42 -- espaço entre mensagens seguidas do mesmo herói

local DEFAULT_STYLE = { color = Color3.fromRGB(255, 250, 190), font = Enum.Font.GothamBold, size = 22, rise = 2.4 }

local TEXT_STYLES = {
	-- tipos genéricos
	damage = { color = Color3.fromRGB(255, 85, 75),  font = Enum.Font.GothamBlack,   size = 30, rise = 3.0 },
	heal   = { color = Color3.fromRGB(105, 240, 130), font = Enum.Font.GothamBlack,  size = 28, rise = 2.7 },
	buff   = { color = Color3.fromRGB(120, 215, 255), font = Enum.Font.GothamBlack,  size = 25, rise = 2.5 },
	debuff = { color = Color3.fromRGB(255, 175, 75),  font = Enum.Font.GothamBlack,  size = 25, rise = 2.5 },
	info   = DEFAULT_STYLE,

	-- identidade própria por habilidade
	rage          = { color = Color3.fromRGB(255, 115, 45),  font = Enum.Font.LuckiestGuy,    size = 32, rise = 3.3 },
	goodLuck      = { color = Color3.fromRGB(255, 214, 84),  font = Enum.Font.PermanentMarker, size = 30, rise = 2.9 },
	poisonAttack  = { color = Color3.fromRGB(150, 240, 105), font = Enum.Font.Creepster,      size = 32, rise = 2.9 },
	aloneIsBetter = { color = Color3.fromRGB(198, 148, 255), font = Enum.Font.SpecialElite,   size = 26, rise = 2.9 },
	beyondFront   = { color = Color3.fromRGB(205, 225, 255), font = Enum.Font.Michroma,       size = 24, rise = 2.9 },
	absorbRoots   = { color = Color3.fromRGB(135, 232, 158), font = Enum.Font.Fondamento,     size = 28, rise = 2.7 },
	brokenDefense = { color = Color3.fromRGB(255, 168, 105), font = Enum.Font.Antique,        size = 27, rise = 2.7 },
	firstPunch    = { color = Color3.fromRGB(255, 138, 118), font = Enum.Font.Bangers,        size = 31, rise = 3.0 },
	trustInTeam   = { color = Color3.fromRGB(150, 200, 255), font = Enum.Font.JosefinSans,    size = 26, rise = 2.6 },
	health        = { color = Color3.fromRGB(140, 240, 175), font = Enum.Font.Fondamento,     size = 27, rise = 2.6 },
	clean         = { color = Color3.fromRGB(225, 245, 255), font = Enum.Font.Kalam,          size = 27, rise = 2.6 },
}

local sayQueue, sayRunning = {}, {}

-- ===== SOM =====
-- Sons de gameplay tocam em 2D (SoundService), não presos ao Part do herói.
-- Motivo: a câmera fica travada a ~90 studs do tabuleiro, e som 3D com
-- EmitterSize padrão (10) cairia pra ~10% do volume nessa distância.
local function PlaySound(name, volumeScale)
	local template = Sounds:FindFirstChild(name)
	if not template then return end

	local sound = template:Clone()
	sound.Volume = template.Volume * (volumeScale or 1)
	sound.Parent = SoundService
	sound:Play()
	Debris:AddItem(sound, (sound.TimeLength > 0 and sound.TimeLength or 5) + 0.5)
end

HeroView.PlaySound = PlaySound

function HeroView.PlayGlobalSound(name)
	PlaySound(name)
end

function HeroView.PlayAttackSound(hero)
	if hero.name == "Blade" then
		PlaySound("SwordSwing")
	elseif table.find(hero.abilities, "poisonAttack") then
		PlaySound("PoisonHiss")
	end
end

function HeroView.PlayHealSound(hero)
	PlaySound("Heal")
end

function HeroView.PlayPlaceSound()
	PlaySound("HeroPlace")
end

-- Habilidades que ganharam som próprio. A skill chama isso só quando o efeito
-- realmente acontece (o goodLuck, por exemplo, não toca quando dá "Nada...").
local SKILL_SOUNDS = {
	goodLuck = "SkillGoodLuck",
	aloneIsBetter = "SkillAlone",
	brokenDefense = "SkillBrokenDefense",
}

function HeroView.PlaySkillSound(key)
	local name = SKILL_SOUNDS[key]
	if name then PlaySound(name) end
end

-- Bolinha de energia viajando do atacante até o alvo + reticícula no impacto,
-- pra deixar ataques à distância (Ranged) mais perceptíveis.
function HeroView.ShowRangedAttack(attacker, target)
	if not attacker.part or not target.part then return end

	local fromPos = attacker.part.Position
	local toPos = target.part.Position

	local reticle = Instance.new("Part")
	reticle.Name = "RangedTarget"
	reticle.Shape = Enum.PartType.Cylinder
	reticle.Size = Vector3.new(0.15, RING_THICKNESS * 3, RING_THICKNESS * 3)
	reticle.CFrame = CFrame.new(toPos - Vector3.new(0, ANCHOR_LIFT * 0.6, 0)) * CFrame.Angles(0, 0, math.rad(90))
	reticle.Color = Color3.fromRGB(255, 90, 80)
	reticle.Material = Enum.Material.Neon
	reticle.Anchored = true
	reticle.CanCollide = false
	reticle.CanQuery = false
	reticle.Transparency = 1
	reticle.Parent = Workspace

	TweenService:Create(reticle, TweenInfo.new(0.12), { Transparency = 0.2 }):Play()
	task.delay(0.28, function()
		if reticle.Parent then
			TweenService:Create(reticle, TweenInfo.new(0.15), { Transparency = 1 }):Play()
			task.delay(0.15, function()
				if reticle.Parent then reticle:Destroy() end
			end)
		end
	end)

	local bolt = Instance.new("Part")
	bolt.Name = "RangedBolt"
	bolt.Shape = Enum.PartType.Ball
	bolt.Size = Vector3.new(0.5, 0.5, 0.5)
	bolt.Color = Color3.fromRGB(255, 235, 150)
	bolt.Material = Enum.Material.Neon
	bolt.Anchored = true
	bolt.CanCollide = false
	bolt.CanQuery = false
	bolt.CFrame = CFrame.new(fromPos)
	bolt.Parent = Workspace

	local tween = TweenService:Create(bolt, TweenInfo.new(0.18, Enum.EasingStyle.Linear), {
		CFrame = CFrame.new(toPos),
	})
	tween:Play()
	tween.Completed:Once(function()
		bolt:Destroy()
	end)
end

-- ===== HELPERS =====
local function GetFolder(name)
	local folder = Workspace:FindFirstChild(name)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = Workspace
	end
	return folder
end

local function GroundCFrame(hexId)
	return CFrame.new(HexGrid.GetWorldPosition(hexId) + Vector3.new(0, TILE_TOP_Y, 0))
end

local function AnchorCFrame(hexId)
	return GroundCFrame(hexId) * CFrame.new(0, ANCHOR_LIFT, 0)
end

-- A cor vem do lado (1 = azul, 2 = vermelho), não de "é o bot?": em PvP os
-- dois lados são jogadores e a câmera é a mesma pros dois.
local function TeamColor(hero)
	return hero.sideIndex == 2 and TEAM_COLOR_PLAYER_2 or TEAM_COLOR_PLAYER_1
end

-- Pendura uma parte na âncora: sem Anchored e presa por WeldConstraint,
-- então acompanha qualquer movimento/tween da âncora.
local function AttachTo(anchor, part)
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.Massless = true
	part.Parent = anchor

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = anchor
	weld.Part1 = part
	weld.Parent = anchor
end

local function BuildTeamRing(anchor, hexId, color)
	local center = HexGrid.GetWorldPosition(hexId) + Vector3.new(0, TILE_TOP_Y + RING_HEIGHT, 0)
	local circumradius = HexGrid.GetHexSize() * RING_SCALE
	local apothem = circumradius * math.sqrt(3) / 2

	for side = 0, 5 do
		local midAngle = math.rad(side * 60 + 30)
		local outward = Vector3.new(math.cos(midAngle), 0, math.sin(midAngle))
		local tangent = Vector3.new(-math.sin(midAngle), 0, math.cos(midAngle))
		local position = center + outward * apothem

		local edge = Instance.new("Part")
		edge.Name = "RingEdge" .. side
		edge.Size = Vector3.new(RING_THICKNESS, RING_THICKNESS, circumradius + RING_THICKNESS)
		edge.CFrame = CFrame.new(position, position + tangent)
		edge.Color = color
		edge.Material = Enum.Material.Neon
		AttachTo(anchor, edge)
	end
end

-- ===== TEXTO FLUTUANTE =====
local function ShowBubble(hero, text, kind)
	if not hero.part or not hero.part.Parent then return end

	local style = TEXT_STYLES[kind] or DEFAULT_STYLE
	local startOffset = Vector3.new(0, SPRITE_HEIGHT * 0.8, 0)

	local bubble = Instance.new("BillboardGui")
	bubble.Name = "FloatingText"
	bubble.Size = UDim2.new(0, 180, 0, 38)
	bubble.StudsOffset = startOffset
	bubble.AlwaysOnTop = true
	bubble.Parent = hero.part

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = style.color
	label.Font = style.font
	label.TextSize = style.size
	label.TextStrokeColor3 = Color3.fromRGB(8, 10, 16)
	label.TextStrokeTransparency = 1
	label.TextTransparency = 1
	label.Parent = bubble

	-- entra suave, sobe, some
	TweenService:Create(label, TweenInfo.new(0.13), {
		TextTransparency = 0, TextStrokeTransparency = 0.25,
	}):Play()

	TweenService:Create(bubble, TweenInfo.new(BUBBLE_LIFETIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		StudsOffset = startOffset + Vector3.new(0, style.rise, 0),
	}):Play()

	task.delay(BUBBLE_LIFETIME * 0.5, function()
		if label.Parent then
			TweenService:Create(label, TweenInfo.new(BUBBLE_LIFETIME * 0.5), {
				TextTransparency = 1, TextStrokeTransparency = 1,
			}):Play()
		end
	end)

	task.delay(BUBBLE_LIFETIME + 0.15, function()
		if bubble then bubble:Destroy() end
	end)
end

-- Enfileira: uma mensagem por vez, nunca sobrepostas.
-- `kind` é um tipo genérico ("damage", "heal", "buff") ou a chave da skill.
function HeroView.Say(hero, text, kind)
	local uid = hero.uid
	sayQueue[uid] = sayQueue[uid] or {}
	table.insert(sayQueue[uid], { text = text, kind = kind or "info" })

	if sayRunning[uid] then return end
	sayRunning[uid] = true

	task.spawn(function()
		while sayQueue[uid] and #sayQueue[uid] > 0 do
			local item = table.remove(sayQueue[uid], 1)
			if not (hero.part and hero.part.Parent) then break end
			ShowBubble(hero, item.text, item.kind)
			task.wait(BUBBLE_GAP)
		end
		sayQueue[uid] = nil
		sayRunning[uid] = nil
	end)
end

-- ===== CRIAÇÃO =====
function HeroView.Create(hero)
	local data = HeroData.GetById(hero.dataId)
	local folder = GetFolder("Heroes")

	local anchor = Instance.new("Part")
	anchor.Name = hero.uid
	anchor.Size = Vector3.new(SPRITE_WIDTH * 0.6, SPRITE_HEIGHT * 0.8, SPRITE_WIDTH * 0.6)
	anchor.CFrame = AnchorCFrame(hero.position)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = true
	anchor:SetAttribute("HeroUid", hero.uid)
	anchor.Parent = folder

	BuildTeamRing(anchor, hero.position, TeamColor(hero))

	if SPRITES_ENABLED then
		local spriteGui = Instance.new("BillboardGui")
		spriteGui.Name = "Sprite"
		spriteGui.Size = UDim2.fromScale(SPRITE_WIDTH, SPRITE_HEIGHT)
		spriteGui.StudsOffsetWorldSpace = Vector3.new(0, SPRITE_HEIGHT / 2 - ANCHOR_LIFT, 0)
		spriteGui.LightInfluence = 0
		spriteGui.Parent = anchor

		local image = Instance.new("ImageLabel")
		image.Name = "Frame"
		image.Size = UDim2.fromScale(1, 1)
		image.BackgroundTransparency = 1
		image.Image = SPRITE_SHEET_ID
		image.ImageRectSize = HeroData.GetFrameSize()
		image.ImageRectOffset = HeroData.GetFrameOffset(data)
		image.ResampleMode = Enum.ResamplerMode.Pixelated
		image.Parent = spriteGui
	else
		local body = Instance.new("Part")
		body.Name = "Body"
		body.Shape = Enum.PartType.Cylinder
		body.Size = Vector3.new(SPRITE_HEIGHT * 0.7, SPRITE_WIDTH * 0.62, SPRITE_WIDTH * 0.62)
		body.CFrame = AnchorCFrame(hero.position) * CFrame.Angles(0, 0, math.rad(90))
		body.Color = data.color
		body.Material = Enum.Material.SmoothPlastic
		AttachTo(anchor, body)
	end

	local statsGui = Instance.new("BillboardGui")
	statsGui.Name = "HeroInfo"
	statsGui.Size = UDim2.new(0, 48, 0, 16)
	statsGui.StudsOffset = Vector3.new(0, -SPRITE_HEIGHT * 0.34, 0)
	statsGui.AlwaysOnTop = true
	statsGui.Parent = anchor

	local row = Instance.new("Frame")
	row.Size = UDim2.fromScale(1, 1)
	row.BackgroundTransparency = 1
	row.Parent = statsGui

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 2)
	layout.Parent = row

	local function badge(name, color, order)
		local frame = Instance.new("Frame")
		frame.Name = name
		frame.Size = UDim2.new(0, 19, 0, 15)
		frame.BackgroundColor3 = color
		frame.BorderSizePixel = 0
		frame.LayoutOrder = order
		frame.Parent = row

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 4)
		corner.Parent = frame

		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(10, 12, 18)
		stroke.Thickness = 1.2
		stroke.Parent = frame

		local value = Instance.new("TextLabel")
		value.Name = "Value"
		value.Size = UDim2.fromScale(1, 1)
		value.BackgroundTransparency = 1
		value.TextColor3 = Color3.new(1, 1, 1)
		value.TextScaled = true
		value.Font = Enum.Font.GothamBold
		value.Parent = frame
	end

	badge("Atk", Color3.fromRGB(52, 100, 175), 1)
	badge("Hp", Color3.fromRGB(65, 155, 85), 2)

	local status = Instance.new("Frame")
	status.Name = "Status"
	status.Size = UDim2.new(0, 15, 0, 15)
	status.LayoutOrder = 3
	status.BackgroundTransparency = 1
	status.ClipsDescendants = true
	status.Parent = row

	-- tira de 3 células: a ImageLabel fica 3x mais larga que a janela (status)
	-- e desliza por escala (Position em múltiplos de -1) pra mostrar só 1 célula
	local statusIcon = Instance.new("ImageLabel")
	statusIcon.Name = "Icon"
	statusIcon.Size = UDim2.new(HeroData.POISON_FRAME_COUNT, 0, 1, 0)
	statusIcon.Position = UDim2.new(0, 0, 0, 0)
	statusIcon.BackgroundTransparency = 1
	statusIcon.ScaleType = Enum.ScaleType.Stretch
	statusIcon.Visible = false
	statusIcon.ResampleMode = Enum.ResamplerMode.Pixelated
	statusIcon.Parent = status

	local statusFallback = Instance.new("TextLabel")
	statusFallback.Name = "Fallback"
	statusFallback.Size = UDim2.fromScale(1, 1)
	statusFallback.BackgroundTransparency = 1
	statusFallback.Text = ""
	statusFallback.TextColor3 = Color3.fromRGB(160, 240, 140)
	statusFallback.TextScaled = true
	statusFallback.Font = Enum.Font.GothamBold
	statusFallback.Parent = status

	hero.part = anchor
	HeroView.UpdateStats(hero)
	return anchor
end

-- ===== ESTADO =====
function HeroView.UpdateStats(hero)
	if not hero.part or not hero.part.Parent then return end

	local statsGui = hero.part:FindFirstChild("HeroInfo")
	local row = statsGui and statsGui:FindFirstChildWhichIsA("Frame")
	if not row then return end

	local atk = row:FindFirstChild("Atk")
	local hp = row:FindFirstChild("Hp")
	local status = row:FindFirstChild("Status")

	if atk then
		atk.Value.Text = tostring(hero.attack)
		local target = hero.attack > hero.baseAttack
			and Color3.fromRGB(85, 155, 240) or Color3.fromRGB(52, 100, 175)
		TweenService:Create(atk, TweenInfo.new(0.25), { BackgroundColor3 = target }):Play()
	end

	if hp then
		local ratio = hero.maxHp > 0 and math.max(hero.currentHp, 0) / hero.maxHp or 0
		hp.Value.Text = tostring(math.max(hero.currentHp, 0))
		local target = ratio > 0.5 and Color3.fromRGB(65, 155, 85)
			or (ratio > 0.25 and Color3.fromRGB(190, 150, 50) or Color3.fromRGB(190, 60, 60))
		TweenService:Create(hp, TweenInfo.new(0.25), { BackgroundColor3 = target }):Play()
	end

	if status then
		local icon = status:FindFirstChild("Icon")
		local fallback = status:FindFirstChild("Fallback")
		local poison = nil
		for _, effect in ipairs(hero.statusEffects) do
			if effect.type == "poison" then poison = effect end
		end

		local spriteId = HeroData.GetPoisonSpriteId()
		if poison and spriteId then
			local stage = HeroData.GetPoisonStageIndex(poison.duration)
			icon.Image = spriteId
			icon.Position = UDim2.new(-stage, 0, 0, 0)
			icon.Visible = true
			fallback.Text = ""
		elseif poison then
			icon.Visible = false
			fallback.Text = "☠"
		else
			icon.Visible = false
			fallback.Text = ""
		end
	end
end

-- ===== MOVIMENTO =====
function HeroView.SetPosition(hero, hexId)
	if not hero.part then return end
	hero.part.CFrame = AnchorCFrame(hexId)
end

function HeroView.WalkPath(hero, path)
	if not hero.part or not path then return end

	for _, hexId in ipairs(path) do
		if not hero.part or not hero.part.Parent then return end

		local tween = TweenService:Create(
			hero.part,
			TweenInfo.new(MOVE_STEP_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
			{ CFrame = AnchorCFrame(hexId) }
		)
		tween:Play()
		PlaySound("FootstepWood")
		task.wait(MOVE_STEP_TIME)
	end
end

-- ===== ANIMAÇÃO =====
-- Com sprites estáticos, feedback é feito por tween. Quando os modelos do
-- Blender entrarem, é aqui que o Animator toca as animações de verdade.
function HeroView.PlayAnimation(hero, animationName)
	if not hero.part or not hero.part.Parent then return end

	local spriteGui = hero.part:FindFirstChild("Sprite")
	local image = spriteGui and spriteGui:FindFirstChild("Frame")

	if animationName == "hit" then
		if image then
			image.ImageColor3 = Color3.fromRGB(255, 110, 110)
			TweenService:Create(image, TweenInfo.new(0.35), { ImageColor3 = Color3.new(1, 1, 1) }):Play()
		end
		PlaySound("Hit")

	elseif animationName == "die" then
		PlaySound("HeroDeath")

	elseif animationName == "attack" then
		local base = hero.part.CFrame
		TweenService:Create(hero.part, TweenInfo.new(0.09, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			CFrame = base * CFrame.new(0, 0.9, 0),
		}):Play()

		task.delay(0.11, function()
			if hero.part and hero.part.Parent then
				TweenService:Create(hero.part, TweenInfo.new(0.14, Enum.EasingStyle.Quad), { CFrame = base }):Play()
			end
		end)
	end
end

-- ===== MORTE =====
function HeroView.Destroy(hero)
	sayQueue[hero.uid] = nil
	if hero.part then
		hero.part:Destroy()
		hero.part = nil
	end
end

function HeroView.CreateGrave(hero)
	local folder = GetFolder("Graves")

	local stone = Instance.new("Part")
	stone.Name = "Grave_" .. hero.uid
	stone.Size = Vector3.new(2.6, 3, 0.7)
	stone.CFrame = GroundCFrame(hero.position) * CFrame.new(0, 1.5, 0)
	stone.Color = Color3.fromRGB(105, 108, 118)
	stone.Material = Enum.Material.Slate
	stone.Anchored = true
	stone.CanCollide = false
	stone.CanQuery = false
	stone.Transparency = 1
	stone.Parent = folder

	local top = Instance.new("Part")
	top.Name = "Top"
	top.Shape = Enum.PartType.Cylinder
	top.Size = Vector3.new(0.7, 2.6, 2.6)
	top.CFrame = stone.CFrame * CFrame.new(0, 1.5, 0) * CFrame.Angles(0, math.rad(90), 0)
	top.Color = stone.Color
	top.Material = stone.Material
	top.Anchored = true
	top.CanCollide = false
	top.CanQuery = false
	top.Transparency = 1
	top.Parent = stone

	-- o túmulo surge desbotando pra dentro em vez de aparecer seco
	TweenService:Create(stone, TweenInfo.new(0.45), { Transparency = 0 }):Play()
	TweenService:Create(top, TweenInfo.new(0.45), { Transparency = 0 }):Play()

	local label = Instance.new("BillboardGui")
	label.Size = UDim2.new(0, 90, 0, 22)
	label.StudsOffset = Vector3.new(0, 3, 0)
	label.AlwaysOnTop = true
	label.Parent = stone

	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Text = "☠ " .. hero.name
	text.TextColor3 = TeamColor(hero)
	text.TextStrokeTransparency = 0.4
	text.TextScaled = true
	text.Font = Enum.Font.GothamBold
	text.Parent = label
end

function HeroView.ClearAll()
	sayQueue, sayRunning = {}, {}
	for _, name in ipairs({ "Heroes", "Graves" }) do
		local folder = Workspace:FindFirstChild(name)
		if folder then folder:Destroy() end
	end
end

return HeroView
