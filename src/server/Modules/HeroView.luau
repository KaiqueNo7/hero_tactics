--[[
	HeroView.lua
	ModuleScript — ServerScriptService/Modules/HeroView

	Toda a apresentação dos heróis. O MatchManager diz o que aconteceu;
	como isso aparece é problema daqui.

	Texto flutuante agora é uma FILA por herói: uma mensagem de cada vez,
	como tooltip de navegador, em vez de várias empilhadas no mesmo ponto.
	Cada tipo (dano, cura, buff) e cada skill tem sua própria identidade.

	Com partidas simultâneas, nada aqui pode ser global. Cada partida monta uma
	`view` — { origin, heroesFolder, gravesFolder, players } — e todo herói
	carrega a sua em `hero.view`. É por ela que sai a posição no mundo, a pasta
	onde o modelo mora e, principalmente, PRA QUEM o som toca: som em
	SoundService é 2D e sairia na tela de todo mundo no servidor, inclusive de
	quem está em outra partida.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")
local SoundService = game:GetService("SoundService")

local HexGrid = require(ReplicatedStorage.Modules.HexGrid)
local HeroData = require(ReplicatedStorage.Modules.HeroData)
local PixelIcons = require(ReplicatedStorage.Modules.PixelIcons)

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
-- A casa hexagonal mede ~9,8 studs de ponta a ponta (HEX_RADIUS 6 no
-- BoardSpawner), e o sprite ocupava 4,2 — o herói ficava pequeno no meio do
-- tabuleiro visto de cima. 5,2 dá presença sem transbordar pra casa vizinha nem
-- tapar o vizinho de trás. Tudo que é derivado (altura, elevação da âncora,
-- posição dos selos de ATK/HP e do texto flutuante) acompanha sozinho.
local SPRITE_WIDTH = 5.2
local TILE_TOP_Y = 0.5
local MOVE_STEP_TIME = 0.22
local BOT_ID = "BOT"

local RING_SCALE = 0.64
local RING_THICKNESS = 0.32
local RING_HEIGHT = 0.08

local TEAM_COLOR_PLAYER_1 = Color3.fromRGB(70, 150, 255)
local TEAM_COLOR_PLAYER_2 = Color3.fromRGB(230, 70, 70)

-- ===== CRACHÁ DE STATUS (abaixo do herói) =====
-- Antes eram dois retângulos coloridos com um número dentro: azul era ataque,
-- verde era vida, e não tinha como saber disso sem alguém contar. Agora cada
-- valor tem ícone próprio, e a moldura dourada dá a leitura de "isto é um
-- painel" em vez de dois quadradinhos soltos.
-- O ícone tem grade 7x7, então o slot mede 14: dois pixels de tela por pixel de
-- desenho, em número inteiro. Com o slot em 11 (o primeiro palpite) cada célula
-- caía em 1,57 px e as diagonais saíam com espessura irregular.
local ICON_SLOT = 14
local BADGE_HEIGHT = 20
local STAT_BADGE_WIDTH = 36
local SQUARE_BADGE_WIDTH = 20
local BADGE_PADDING = 2

local BADGE_BG = Color3.fromRGB(26, 23, 32)
local BADGE_GOLD = Color3.fromRGB(255, 205, 90)
local ICON_RED = Color3.fromRGB(238, 82, 82)

-- Ataque acima do base acende em verde. Verde e não dourado de propósito: o
-- dourado é a moldura de todos os crachás, então um buff dourado seria a mesma
-- cor de sempre e passaria batido justamente no turno em que importa.
local BUFF_BG = Color3.fromRGB(20, 52, 30)
local BUFF_STROKE = Color3.fromRGB(126, 245, 158)
local BUFF_TEXT = Color3.fromRGB(180, 255, 200)

-- Vida some do branco pro vermelho conforme cai
local HP_TEXT_FULL = Color3.new(1, 1, 1)
local HP_TEXT_HURT = Color3.fromRGB(255, 214, 120)
local HP_TEXT_CRITICAL = Color3.fromRGB(255, 120, 120)

-- Passiva do herói (data.ability) -> ícone e cor do selo ao lado da vida
local ABILITY_BADGES = {
	Taunt  = { icon = "taunt",  color = Color3.fromRGB(198, 202, 212) },
	Sprint = { icon = "sprint", color = Color3.fromRGB(132, 206, 255) },
	Ranged = { icon = "ranged", color = Color3.fromRGB(255, 200, 110) },
}

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
-- Sons de gameplay tocam em 2D, não presos ao Part do herói: a câmera fica
-- travada a ~90 studs do tabuleiro, e som 3D com EmitterSize padrão (10) cairia
-- pra ~10% do volume nessa distância.
--
-- Mas 2D no servidor toca pra TODO MUNDO. Com partidas simultâneas, o jogador
-- ouviria o golpe da arena vizinha como se fosse na dele. Então o servidor não
-- toca nada: manda o nome do som pelos clientes daquela partida, e cada um toca
-- localmente (SoundClient). `view.players` é a plateia — em partida contra bot,
-- é uma pessoa só.
local MatchSound = ReplicatedStorage:WaitForChild("Remotes"):FindFirstChild("MatchSound")
if not MatchSound then
	MatchSound = Instance.new("RemoteEvent")
	MatchSound.Name = "MatchSound"
	MatchSound.Parent = ReplicatedStorage.Remotes
end

local function PlaySound(name, view, volumeScale)
	if not Sounds:FindFirstChild(name) then return end
	if not view then return end

	for _, player in ipairs(view.players or {}) do
		if player.Parent then
			MatchSound:FireClient(player, name, volumeScale)
		end
	end
end

HeroView.PlaySound = PlaySound

function HeroView.PlayMatchSound(view, name)
	PlaySound(name, view)
end

function HeroView.PlayAttackSound(hero)
	if hero.name == "Blade" then
		PlaySound("SwordSwing", hero.view)
	elseif table.find(hero.abilities, "poisonAttack") then
		PlaySound("PoisonHiss", hero.view)
	end
end

function HeroView.PlayHealSound(hero)
	PlaySound("Heal", hero.view)
end

function HeroView.PlayPlaceSound(view)
	PlaySound("HeroPlace", view)
end

-- Habilidades que ganharam som próprio. A skill chama isso só quando o efeito
-- realmente acontece (o goodLuck, por exemplo, não toca quando dá "Nada...").
local SKILL_SOUNDS = {
	goodLuck = "SkillGoodLuck",
	aloneIsBetter = "SkillAlone",
	brokenDefense = "SkillBrokenDefense",
}

function HeroView.PlaySkillSound(key, view)
	local name = SKILL_SOUNDS[key]
	if name then PlaySound(name, view) end
end

-- As duas peças do tiro (a bolinha e a retícula) são criadas UMA vez por
-- partida e reaproveitadas. Antes nasciam e morriam a cada ataque à distância —
-- e como o servidor só resolve uma ação por vez, nunca houve mais de um tiro no
-- ar: criar e destruir era trabalho de replicação puro, no meio do golpe.
local function EnsureBolt(view)
	if view.bolt and view.bolt.Parent then return view.bolt, view.reticle end

	local bolt = Instance.new("Part")
	bolt.Name = "RangedBolt"
	bolt.Shape = Enum.PartType.Ball
	bolt.Size = Vector3.new(0.5, 0.5, 0.5)
	bolt.Color = Color3.fromRGB(255, 235, 150)
	bolt.Material = Enum.Material.Neon
	bolt.Anchored = true
	bolt.CanCollide = false
	bolt.CanQuery = false
	bolt.CastShadow = false
	bolt.Transparency = 1
	bolt.Parent = view.heroesFolder

	local reticle = Instance.new("Part")
	reticle.Name = "RangedTarget"
	reticle.Shape = Enum.PartType.Cylinder
	reticle.Size = Vector3.new(0.15, RING_THICKNESS * 3, RING_THICKNESS * 3)
	reticle.Color = Color3.fromRGB(255, 90, 80)
	reticle.Material = Enum.Material.Neon
	reticle.Anchored = true
	reticle.CanCollide = false
	reticle.CanQuery = false
	reticle.CastShadow = false
	reticle.Transparency = 1
	reticle.Parent = view.heroesFolder

	view.bolt, view.reticle = bolt, reticle
	return bolt, reticle
end

-- Bolinha de energia viajando do atacante até o alvo + retícula no impacto,
-- pra deixar ataques à distância (Ranged) mais perceptíveis.
function HeroView.ShowRangedAttack(attacker, target)
	if not attacker.part or not target.part then return end

	local view = attacker.view
	if not view then return end

	local bolt, reticle = EnsureBolt(view)
	local fromPos = attacker.part.Position
	local toPos = target.part.Position

	reticle.CFrame = CFrame.new(toPos - Vector3.new(0, ANCHOR_LIFT * 0.6, 0)) * CFrame.Angles(0, 0, math.rad(90))
	TweenService:Create(reticle, TweenInfo.new(0.12), { Transparency = 0.2 }):Play()
	task.delay(0.28, function()
		if reticle.Parent then
			TweenService:Create(reticle, TweenInfo.new(0.15), { Transparency = 1 }):Play()
		end
	end)

	bolt.CFrame = CFrame.new(fromPos)
	bolt.Transparency = 0

	local tween = TweenService:Create(bolt, TweenInfo.new(0.18, Enum.EasingStyle.Linear), {
		CFrame = CFrame.new(toPos),
	})
	tween:Play()
	tween.Completed:Once(function()
		if bolt.Parent then bolt.Transparency = 1 end
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

-- Cada partida tem suas pastas e sua origem no mundo. Chamada uma vez pelo
-- MatchManager; o resultado vive em match.view e em hero.view.
function HeroView.CreateView(matchId, origin, players)
	return {
		id = matchId,
		origin = origin,
		players = players,
		heroesFolder = GetFolder("Heroes_" .. matchId),
		gravesFolder = GetFolder("Graves_" .. matchId),
	}
end

function HeroView.DestroyView(view)
	if not view then return end
	for _, folder in ipairs({ view.heroesFolder, view.gravesFolder }) do
		if folder and folder.Parent then folder:Destroy() end
	end
end

local function GroundCFrame(hexId, origin)
	return CFrame.new(HexGrid.GetWorldPosition(hexId, origin) + Vector3.new(0, TILE_TOP_Y, 0))
end

local function AnchorCFrame(hexId, origin)
	return GroundCFrame(hexId, origin) * CFrame.new(0, ANCHOR_LIFT, 0)
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

local function BuildTeamRing(anchor, hexId, color, origin)
	local center = HexGrid.GetWorldPosition(hexId, origin) + Vector3.new(0, TILE_TOP_Y + RING_HEIGHT, 0)
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
-- O balão é REAPROVEITADO, não recriado.
--
-- Antes cada mensagem criava um BillboardGui + TextLabel e os destruía ~1s
-- depois. Uma troca de golpes com contra-ataque solta de 4 a 8 mensagens (dano,
-- cura, buff, nome de skill), e cada BillboardGui novo obriga o cliente a montar
-- e começar a desenhar um objeto de GUI no meio da ação — era engasgo na hora
-- exata do ataque, justamente quando o jogador está olhando.
--
-- Como a fila do Say já mostra uma mensagem por vez por herói, um balão por
-- herói basta: o Create monta ele junto com o boneco e aqui só trocamos texto,
-- cor e fonte.
local function GetBubble(hero)
	if not hero.part or not hero.part.Parent then return nil end
	return hero.part:FindFirstChild("FloatingText")
end

local function ShowBubble(hero, text, kind)
	local bubble = GetBubble(hero)
	if not bubble then return end

	local label = bubble:FindFirstChildWhichIsA("TextLabel")
	if not label then return end

	local style = TEXT_STYLES[kind] or DEFAULT_STYLE
	local startOffset = Vector3.new(0, SPRITE_HEIGHT * 0.8, 0)

	-- cancela o que sobrou da mensagem anterior antes de reusar
	bubble.StudsOffset = startOffset
	label.Text = text
	label.TextColor3 = style.color
	label.Font = style.font
	label.TextSize = style.size
	label.TextTransparency = 1
	label.TextStrokeTransparency = 1
	bubble.Enabled = true

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

	-- desligar em vez de destruir: o BillboardGui desligado sai do desenho e
	-- volta na próxima mensagem sem custo de criação
	task.delay(BUBBLE_LIFETIME + 0.15, function()
		if bubble.Parent then bubble.Enabled = false end
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
	local view = hero.view
	local folder = view.heroesFolder

	local anchor = Instance.new("Part")
	anchor.Name = hero.uid
	anchor.Size = Vector3.new(SPRITE_WIDTH * 0.6, SPRITE_HEIGHT * 0.8, SPRITE_WIDTH * 0.6)
	anchor.CFrame = AnchorCFrame(hero.position, view.origin)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = true
	anchor:SetAttribute("HeroUid", hero.uid)
	anchor.Parent = folder

	BuildTeamRing(anchor, hero.position, TeamColor(hero), view.origin)

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
		body.CFrame = AnchorCFrame(hero.position, view.origin) * CFrame.Angles(0, 0, math.rad(90))
		body.Color = data.color
		body.Material = Enum.Material.SmoothPlastic
		AttachTo(anchor, body)
	end

	-- Balão de texto flutuante, montado UMA vez e reaproveitado a cada mensagem
	-- (ver ShowBubble). Nasce desligado.
	local bubble = Instance.new("BillboardGui")
	bubble.Name = "FloatingText"
	bubble.Size = UDim2.new(0, 180, 0, 38)
	bubble.StudsOffset = Vector3.new(0, SPRITE_HEIGHT * 0.8, 0)
	bubble.AlwaysOnTop = true
	bubble.Enabled = false
	bubble.Parent = anchor

	local bubbleLabel = Instance.new("TextLabel")
	bubbleLabel.Name = "Text"
	bubbleLabel.Size = UDim2.fromScale(1, 1)
	bubbleLabel.BackgroundTransparency = 1
	bubbleLabel.Text = ""
	bubbleLabel.TextStrokeColor3 = Color3.fromRGB(8, 10, 16)
	bubbleLabel.TextStrokeTransparency = 1
	bubbleLabel.TextTransparency = 1
	bubbleLabel.Parent = bubble

	-- A caixa é larga o bastante pro pior caso (ataque + vida + passiva + veneno);
	-- o UIListLayout centraliza o que existir, então herói sem passiva continua
	-- com o crachá curtinho e centrado.
	local statsGui = Instance.new("BillboardGui")
	statsGui.Name = "HeroInfo"
	statsGui.Size = UDim2.new(0, 124, 0, BADGE_HEIGHT + 2)
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
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, BADGE_PADDING)
	layout.Parent = row

	-- Casca comum: fundo escuro, canto arredondado e a moldura dourada.
	local function shell(name, width, order)
		local frame = Instance.new("Frame")
		frame.Name = name
		frame.Size = UDim2.new(0, width, 0, BADGE_HEIGHT)
		frame.BackgroundColor3 = BADGE_BG
		frame.BorderSizePixel = 0
		frame.LayoutOrder = order
		frame.Parent = row

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 5)
		corner.Parent = frame

		local stroke = Instance.new("UIStroke")
		stroke.Name = "Edge"
		stroke.Color = BADGE_GOLD
		stroke.Thickness = 1.1
		stroke.Transparency = 0.15
		stroke.Parent = frame

		return frame
	end

	-- Ícone à esquerda, número à direita — a mesma leitura dos dois crachás.
	local function statBadge(name, iconName, iconColor, order)
		local frame = shell(name, STAT_BADGE_WIDTH, order)

		local iconSlot = Instance.new("Frame")
		iconSlot.Name = "IconSlot"
		iconSlot.AnchorPoint = Vector2.new(0, 0.5)
		iconSlot.Position = UDim2.new(0, 3, 0.5, 0)
		iconSlot.Size = UDim2.new(0, ICON_SLOT, 0, ICON_SLOT)
		iconSlot.BackgroundTransparency = 1
		iconSlot.ZIndex = 2
		iconSlot.Parent = frame

		PixelIcons.Build(iconName, iconSlot, iconColor, 2)

		local value = Instance.new("TextLabel")
		value.Name = "Value"
		value.AnchorPoint = Vector2.new(1, 0.5)
		value.Position = UDim2.new(1, -3, 0.5, 0)
		value.Size = UDim2.new(0, STAT_BADGE_WIDTH - ICON_SLOT - 8, 0, 14)
		value.BackgroundTransparency = 1
		value.TextColor3 = Color3.new(1, 1, 1)
		value.TextScaled = true
		value.Font = Enum.Font.GothamBlack
		value.ZIndex = 2
		value.Parent = frame

		return frame
	end

	statBadge("Atk", "sword", ICON_RED, 1)
	statBadge("Hp", "heart", ICON_RED, 2)

	-- Passiva: só existe pra quem tem uma. Nada aqui muda durante a partida, por
	-- isso é montado uma vez e o UpdateStats nem olha pra ele.
	local abilityBadge = ABILITY_BADGES[hero.ability]
	if abilityBadge then
		local frame = shell("Ability", SQUARE_BADGE_WIDTH, 3)

		local iconSlot = Instance.new("Frame")
		iconSlot.Name = "IconSlot"
		iconSlot.AnchorPoint = Vector2.new(0.5, 0.5)
		iconSlot.Position = UDim2.fromScale(0.5, 0.5)
		iconSlot.Size = UDim2.new(0, ICON_SLOT, 0, ICON_SLOT)
		iconSlot.BackgroundTransparency = 1
		iconSlot.ZIndex = 2
		iconSlot.Parent = frame

		PixelIcons.Build(abilityBadge.icon, iconSlot, abilityBadge.color, 2)
	end

	-- Veneno ganha a mesma casca dos outros, pra não ser o único selo solto no
	-- meio de uma fileira emoldurada. O recorte da tira mora no slot interno.
	local status = shell("Status", SQUARE_BADGE_WIDTH, 5)
	status.Visible = false

	local statusSlot = Instance.new("Frame")
	statusSlot.Name = "Slot"
	statusSlot.AnchorPoint = Vector2.new(0.5, 0.5)
	statusSlot.Position = UDim2.fromScale(0.5, 0.5)
	statusSlot.Size = UDim2.new(0, ICON_SLOT, 0, ICON_SLOT)
	statusSlot.BackgroundTransparency = 1
	statusSlot.ClipsDescendants = true
	statusSlot.ZIndex = 2
	statusSlot.Parent = status

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
	statusIcon.ZIndex = 3
	statusIcon.Parent = statusSlot

	local statusFallback = Instance.new("TextLabel")
	statusFallback.Name = "Fallback"
	statusFallback.Size = UDim2.fromScale(1, 1)
	statusFallback.BackgroundTransparency = 1
	statusFallback.Text = ""
	statusFallback.TextColor3 = Color3.fromRGB(160, 240, 140)
	statusFallback.TextScaled = true
	statusFallback.Font = Enum.Font.GothamBold
	statusFallback.ZIndex = 3
	statusFallback.Parent = statusSlot

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

		-- Buffado = fundo e número em verde, com a moldura mais grossa. O ícone
		-- de espada continua vermelho: ele é a identidade do crachá, e trocar a
		-- cor dele junto faria os dois selos ficarem verdes e indistinguíveis.
		local buffed = hero.attack > hero.baseAttack
		local edge = atk:FindFirstChild("Edge")

		TweenService:Create(atk, TweenInfo.new(0.25), {
			BackgroundColor3 = buffed and BUFF_BG or BADGE_BG,
		}):Play()

		TweenService:Create(atk.Value, TweenInfo.new(0.25), {
			TextColor3 = buffed and BUFF_TEXT or Color3.new(1, 1, 1),
		}):Play()

		if edge then
			TweenService:Create(edge, TweenInfo.new(0.25), {
				Color = buffed and BUFF_STROKE or BADGE_GOLD,
				Thickness = buffed and 2 or 1.1,
				Transparency = buffed and 0 or 0.15,
			}):Play()
		end
	end

	if hp then
		local ratio = hero.maxHp > 0 and math.max(hero.currentHp, 0) / hero.maxHp or 0
		hp.Value.Text = tostring(math.max(hero.currentHp, 0))

		-- Aqui quem muda de cor é o NÚMERO, não o fundo: com o coração vermelho
		-- fixo do lado, pintar o crachá inteiro de vermelho aos 20% de vida
		-- apagava o próprio ícone contra o fundo.
		local target = ratio > 0.5 and HP_TEXT_FULL
			or (ratio > 0.25 and HP_TEXT_HURT or HP_TEXT_CRITICAL)
		TweenService:Create(hp.Value, TweenInfo.new(0.25), { TextColor3 = target }):Play()
	end

	local statusSlot = status and status:FindFirstChild("Slot")
	if statusSlot then
		local icon = statusSlot:FindFirstChild("Icon")
		local fallback = statusSlot:FindFirstChild("Fallback")
		local poison = nil
		for _, effect in ipairs(hero.statusEffects) do
			if effect.type == "poison" then poison = effect end
		end

		-- o selo inteiro some sem veneno: crachá vazio com moldura dourada
		-- parecia um ícone que não carregou
		status.Visible = poison ~= nil

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
	hero.part.CFrame = AnchorCFrame(hexId, hero.view.origin)
end

function HeroView.WalkPath(hero, path)
	if not hero.part or not path then return end

	for _, hexId in ipairs(path) do
		if not hero.part or not hero.part.Parent then return end

		local tween = TweenService:Create(
			hero.part,
			TweenInfo.new(MOVE_STEP_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
			{ CFrame = AnchorCFrame(hexId, hero.view.origin) }
		)
		tween:Play()
		PlaySound("FootstepWood", hero.view)
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
		PlaySound("Hit", hero.view)

	elseif animationName == "die" then
		PlaySound("HeroDeath", hero.view)

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
	local folder = hero.view.gravesFolder

	local stone = Instance.new("Part")
	stone.Name = "Grave_" .. hero.uid
	stone.Size = Vector3.new(2.6, 3, 0.7)
	stone.CFrame = GroundCFrame(hero.position, hero.view.origin) * CFrame.new(0, 1.5, 0)
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

	-- O nome ficava grande e flutuando ACIMA da lápide, bem em cima das casas
	-- vizinhas — e BillboardGui come o clique de quem estiver atrás dela. Agora
	-- é uma etiqueta pequena no pé do túmulo, dentro da própria casa, e sem a
	-- caveira (que só engordava o texto).
	local label = Instance.new("BillboardGui")
	label.Name = "GraveLabel"
	label.Size = UDim2.new(0, 52, 0, 12)
	label.StudsOffset = Vector3.new(0, -1.75, 0)
	label.AlwaysOnTop = true
	label.Parent = stone

	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Text = hero.name
	text.TextColor3 = TeamColor(hero)
	text.TextStrokeTransparency = 0.5
	text.TextScaled = true
	text.Font = Enum.Font.GothamBold
	text.Parent = label
end

-- Limpa só o que é daquela partida: as outras continuam rodando ao lado.
-- As filas de fala são varridas pelo prefixo do uid (matchId_...), porque herói
-- morto já perdeu o Part e não apareceria mais na pasta.
function HeroView.ClearMatch(view)
	if not view then return end

	local prefix = tostring(view.id) .. "_"
	for uid in pairs(sayQueue) do
		if uid:sub(1, #prefix) == prefix then sayQueue[uid] = nil end
	end
	for uid in pairs(sayRunning) do
		if uid:sub(1, #prefix) == prefix then sayRunning[uid] = nil end
	end

	for _, folder in ipairs({ view.heroesFolder, view.gravesFolder }) do
		if folder and folder.Parent then
			folder:ClearAllChildren()
		end
	end
end

return HeroView
