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

if SPRITE_SHEET_ID then
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
local SPRITE_WIDTH = 5.8

-- ===== PISO EM PIXELS DO SPRITE =====
-- BillboardGui com Size em Scale mede STUDS: encolhe com o zoom. Com Size em
-- Offset mede PIXELS: fica constante. O crachá de status usa Offset, o sprite
-- usava só Scale — então afastando a câmera o herói caía de 68 para 38 px de
-- altura enquanto o crachá continuava com os mesmos 124 px de largura. O boneco
-- ficava menor que a própria ficha dele.
--
-- A correção é usar os DOIS ao mesmo tempo: o Roblox soma as duas partes, então
-- a parcela em Scale mantém a perspectiva (quem está longe no tabuleiro parece
-- mais longe) e a parcela em Offset é um piso que não deixa o herói sumir.
--
-- Isso muda a altura desenhada conforme o zoom, e um StudsOffset fixo em studs
-- deixaria os pés flutuando. Quem resolve é o SizeOffset lá embaixo: ele
-- desloca em fração do PRÓPRIO tamanho, então a base do sprite fica colada na
-- casa em qualquer zoom.
local SPRITE_PIXEL_FLOOR_H = 18
local SPRITE_PIXEL_FLOOR_W = 13 -- mesma proporção do quadro (165x231)

local TILE_TOP_Y = 0.5
local MOVE_STEP_TIME = 0.22
local BOT_ID = "BOT"

local RING_SCALE = 0.64
local RING_THICKNESS = 0.32
local RING_HEIGHT = 0.08

-- Giro da lápide em torno do eixo vertical. A laje é chata (2,6 de largura por
-- 0,7 de espessura), então o ângulo decide se o jogador vê a FACE dela ou só um
-- risco de perfil.
--
-- Nasceu em 0°, encarando o eixo Z, que era de frente pra câmera de então. Com a
-- câmera reposicionada pro azimute 91° (olhando o tabuleiro quase de lado), esse
-- mesmo 0° virou exatamente o pior caso: a lápide de canto, fina como uma tábua.
-- 45° põe ela na diagonal — mostra face e espessura ao mesmo tempo, e ainda
-- desalinha do quadriculado das casas, que é o que faz um cemitério parecer
-- cemitério em vez de fileira de peças.
local GRAVE_YAW = 45

local TEAM_COLOR_PLAYER_1 = Color3.fromRGB(70, 150, 255)
local TEAM_COLOR_PLAYER_2 = Color3.fromRGB(230, 70, 70)

-- ===== CRACHÁ DE STATUS (abaixo do herói) =====
-- Cada valor tem ícone próprio (espada = ataque, coração = vida), e a moldura
-- dourada dá a leitura de "isto é um painel" em vez de dois quadradinhos soltos.
-- O ícone tem grade 7x7, então o slot mede 14: dois pixels de tela por pixel de
-- desenho, em número inteiro. Com o slot em 11 (o primeiro palpite) cada célula
-- caía em 1,57 px e as diagonais saíam com espessura irregular.
--
-- Passiva (Taunt/Sprint/Ranged), veneno e gelo ficam NESTA fileira, ao lado do
-- ataque e da vida. Já tentei mandar esses três só pro retrato na coluna
-- lateral pra desafogar o tabuleiro: é informação crucial pra decidir a jogada,
-- e no canto da tela ela passa despercebida bem na hora em que importa. O lugar
-- dela é junto do boneco. O modal (clique no retrato) segue existindo, mas como
-- consulta detalhada, não como o único caminho.
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

-- Gelo do Kor: floco azul-claro no crachá enquanto o inimigo estiver congelado
local FREEZE_ICON_COLOR = Color3.fromRGB(150, 225, 255)

-- Passiva do herói (data.ability) -> ícone e cor do selo ao lado da vida
local ABILITY_BADGES = {
	Taunt  = { icon = "taunt",  color = Color3.fromRGB(198, 202, 212) },
	Sprint = { icon = "sprint", color = Color3.fromRGB(132, 206, 255) },
	Ranged = { icon = "ranged", color = Color3.fromRGB(255, 200, 110) },
}

local SPRITE_HEIGHT = SPRITE_WIDTH * (HeroData.FRAME_HEIGHT / HeroData.FRAME_WIDTH)
local ANCHOR_LIFT = SPRITE_HEIGHT * 0.4

-- ===== ORDEM DE DESENHO ENTRE O HERÓI E O CRACHÁ DELE =====
-- ZIndex NÃO resolve isto: ele só ordena filhos DENTRO de um mesmo BillboardGui,
-- e o desenho do herói e o crachá são dois BillboardGuis irmãos. Entre eles quem
-- manda é (1) AlwaysOnTop e (2) a distância até a câmera.
--
-- O crachá era AlwaysOnTop, então passava por cima de tudo: dos pés do próprio
-- herói e — pior — dos OUTROS heróis e do cenário do tabuleiro. Desligando isso
-- ele volta a disputar profundidade como qualquer coisa em cena, e a hierarquia
-- pedida cai sozinha: herói da frente tapa crachá de quem está atrás, barril na
-- frente tapa o crachá atrás dele.
--
-- Sobra o empate: herói e crachá saem da MESMA âncora, logo à mesma distância da
-- câmera, e empate em profundidade é ordem indefinida (pode até piscar). O
-- desempate é puxar o DESENHO meio dedo na direção da câmera. Mexe no herói, e
-- não no crachá, de propósito: o crachá flutua a meio stud do tabuleiro, e
-- empurrá-lo pra trás o afundaria na casa; o desenho está em pleno ar e sobe uns
-- 1,5 px na tela, que ninguém vê.
--
-- StudsOffset é medido no eixo da CÂMERA, então isso vale de qualquer ângulo.
-- Se algum dia o herói aparecer ATRÁS do próprio crachá, o sinal aqui está
-- invertido nesta versão do engine — troque por -0.25.
local SPRITE_DEPTH_BIAS = 0.25

-- ===== ESTILOS DE TEXTO FLUTUANTE =====
local BUBBLE_LIFETIME = 1.5 -- quanto tempo uma mensagem sozinha fica na tela

-- Espaço entre mensagens seguidas do MESMO herói. Cada herói tem um balão só,
-- reaproveitado: a mensagem seguinte sobrescreve a anterior quando o GAP vence.
--
-- TEM QUE CABER NO RITMO DO JOGO, não no conforto de leitura. As ações que
-- geram número são mais rápidas que isto: o bot age a cada 0,70s
-- (BOT_ACTION_DELAY), o contra-ataque resolve em 0,40s (COUNTER_ATTACK_DELAY) e
-- o passo de movimento leva 0,22s. Com o GAP acima dessas marcas a fila enche
-- mais rápido do que esvazia, o número exibido atrasa em relação ao golpe que o
-- causou e a partida inteira parece engasgada — foi o que aconteceu quando isto
-- esteve em 0,75s. Quem resolve a legibilidade é o TAMANHO da fonte, ali
-- embaixo, que não custa tempo nenhum.
local BUBBLE_GAP = 0.4

-- Teto da fila por herói. Numa rajada (dano + contra-ataque + veneno na mesma
-- janela) as mensagens velhas são descartadas em vez de exibidas com atraso: o
-- que importa é o que acabou de acontecer, não a fila de tudo que já passou.
-- Sem este teto, o GAP sozinho não impede o acúmulo — só o torna mais lento.
local BUBBLE_QUEUE_MAX = 2

local DEFAULT_STYLE = { color = Color3.fromRGB(255, 250, 190), font = Enum.Font.GothamBold, size = 28, rise = 2.4 }

-- Só os números agora: o balão perdeu os gritos das habilidades ("Veneno!",
-- "Esmaga!") pros efeitos de partícula, e ficou com o que ele fazia melhor —
-- dizer quanto de vida entrou ou saiu.
--
-- Corpos grandes de propósito: a câmera fica a ~75 studs e o número disputa
-- espaço com o sprite, o crachá e o tabuleiro pintado embaixo dele.
local TEXT_STYLES = {
	damage = { color = Color3.fromRGB(255, 85, 75),  font = Enum.Font.GothamBlack,   size = 44, rise = 3.4 },
	heal   = { color = Color3.fromRGB(105, 240, 130), font = Enum.Font.GothamBlack,  size = 40, rise = 3.1 },
	buff   = { color = Color3.fromRGB(120, 215, 255), font = Enum.Font.GothamBlack,  size = 34, rise = 2.8 },
	debuff = { color = Color3.fromRGB(255, 175, 75),  font = Enum.Font.GothamBlack,  size = 34, rise = 2.8 },
	info   = DEFAULT_STYLE,
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
	elseif hero.name == "Kor" then
		PlaySound("IceSwing", hero.view)
	elseif hero.name == "Dante" then
		PlaySound("arrowSwing", hero.view)
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

-- ===== EFEITOS VISUAIS DE HABILIDADE =====
-- Cada skill tinha um grito próprio ("Veneno!", "Esmaga!", "Muahauhauhaua!") com
-- fonte e cor próprias. Era texto pedindo leitura no meio da ação, em cima do
-- tabuleiro, e ainda disputava a fila do balão com os números de dano e cura —
-- que são o que o jogador realmente precisa ver. Agora cada habilidade solta um
-- jato de partículas com cor, tamanho e direção próprios: reconhece-se de
-- relance, sem parar pra ler, e o balão fica só pros números.
--
-- As texturas são as que já vêm no cliente (rbxasset://), então não há upload
-- nem risco de quadrado cinza no lugar do efeito.
local FX_SPARK = "rbxasset://textures/particles/sparkles_main.dds"
local FX_SMOKE = "rbxasset://textures/particles/smoke_main.dds"

-- shape: "burst" explode pra fora (impacto), "rise" sobe do chão (buff/cura)
--
-- Os tamanhos parecem grandes escritos aqui, e são: a câmera fica a ~90 studs do
-- tabuleiro e o sprite do herói tem 5,8 de largura. Com partícula de 1 stud o
-- efeito virava um pontinho — e pior, o billboard do herói tapava quase tudo,
-- porque a rajada nascia dentro do desenho e não tinha velocidade pra sair dele.
-- Partícula grande + velocidade alta é o que faz o efeito escapar da silhueta e
-- ser visto de onde o jogador está olhando.
local SKILL_EFFECTS = {
	poisonAttack  = { color = Color3.fromRGB(120, 235, 90),  texture = FX_SMOKE, shape = "rise",  count = 18, size = 2.6, speed = 7 },
	rage          = { color = Color3.fromRGB(255, 120, 45),  texture = FX_SMOKE, shape = "burst", count = 20, size = 3.2, speed = 17 },
	brokenDefense = { color = Color3.fromRGB(255, 170, 90),  texture = FX_SPARK, shape = "burst", count = 18, size = 2.5, speed = 15 },
	aloneIsBetter = { color = Color3.fromRGB(190, 140, 255), texture = FX_SMOKE, shape = "burst", count = 22, size = 3.0, speed = 14 },
	firstPunch    = { color = Color3.fromRGB(255, 140, 110), texture = FX_SPARK, shape = "rise",  count = 16, size = 2.2, speed = 8 },
	goodLuck      = { color = Color3.fromRGB(255, 215, 90),  texture = FX_SPARK, shape = "rise",  count = 20, size = 2.2, speed = 9 },
	absorbRoots   = { color = Color3.fromRGB(130, 240, 160), texture = FX_SPARK, shape = "rise",  count = 18, size = 2.2, speed = 8 },
	clean         = { color = Color3.fromRGB(230, 250, 255), texture = FX_SPARK, shape = "rise",  count = 16, size = 2.0, speed = 9 },
	iceEffect     = { color = Color3.fromRGB(150, 225, 255), texture = FX_SPARK, shape = "burst", count = 22, size = 2.4, speed = 16 },

	-- a tempestade é a morte do Kor: mais partícula e mais alcance que o gelo comum
	iceStorm      = { color = Color3.fromRGB(195, 245, 255), texture = FX_SPARK, shape = "burst", count = 40, size = 3.0, speed = 24 },

	-- o faro é tique de passiva (acontece direto): discreto de propósito, senão
	-- o Merlin vira uma fonte de fumaça vermelha a cada morte no tabuleiro
	bloodScent    = { color = Color3.fromRGB(190, 60, 60),   texture = FX_SMOKE, shape = "rise",  count = 12, size = 2.0, speed = 6 },

	-- o Frenesi é a virada do personagem e só acontece uma vez: explode
	frenzy        = { color = Color3.fromRGB(235, 45, 40),   texture = FX_SPARK, shape = "burst", count = 36, size = 3.0, speed = 20 },

	-- o goodLuck que não deu sorte: fumacinha cinza, pra ficar claro que a
	-- habilidade rodou e não deu em nada (antes era o "Nada..." escrito)
	goodLuckFail  = { color = Color3.fromRGB(140, 140, 150), texture = FX_SMOKE, shape = "rise",  count = 8,  size = 2.2, speed = 3 },

	-- prêmios do barril: sobem do herói que quebrou, com as cores que o jogo já
	-- usa pra vida (verde) e pra ataque (o mesmo âmbar do crachá de buff)
	barrelHeal    = { color = Color3.fromRGB(120, 245, 150), texture = FX_SPARK, shape = "rise",  count = 20, size = 2.4, speed = 9 },
	barrelAttack  = { color = Color3.fromRGB(255, 200, 90),  texture = FX_SPARK, shape = "rise",  count = 20, size = 2.4, speed = 9 },
}

-- ===== CORTE DO BLADE (IMAGEM ANIMADA) =====
-- O golpe do Blade não é jato de partícula: é UM quadro grande, de frente pra
-- câmera, cruzando o inimigo — uma animação de 16 poses numa grade 4x4 que roda
-- em 0,25s. Veio do pacote "SwordSlash" (asset 16228071670); dele o que importa
-- é a textura e os números abaixo, então está tudo em código. Nada depende de um
-- modelo guardado no place, que não entra no Rojo nem no git.
local FLIPBOOK_EFFECTS = {
	beyondFront = {
		texture = "rbxassetid://16227989129",
		layout = Enum.ParticleFlipbookLayout.Grid4x4,
		framerate = 16,
		lifetime = 0.25,

		-- O pacote vem com 10, que é quase exatamente a largura de uma casa
		-- (~9,8 de ponta a ponta). Só que o desenho é um risco fino e horizontal,
		-- a câmera fica a ~90 studs e a animação inteira dura 0,25s: nesse tamanho
		-- o corte passava despercebido. 13 transborda um pouco a casa e é o que
		-- faz ele LER como um golpe atravessando o inimigo.
		size = 13,
	},
}

-- Um emissor por herói, montado na primeira vez e RECONFIGURADO a cada uso.
-- Criar e destruir ParticleEmitter no meio do golpe é o mesmo engasgo que o
-- balão de texto custava antes de virar objeto reaproveitado.
local function EnsureEmitter(hero)
	local part = hero.part
	if not (part and part.Parent) then return nil end

	local attachment = part:FindFirstChild("SkillFx")
	if attachment then return attachment:FindFirstChild("Emitter") end

	attachment = Instance.new("Attachment")
	attachment.Name = "SkillFx"
	-- na altura do peito do desenho, não no centro da âncora: a rajada saindo do
	-- meio do corpo se espalha em volta da cabeça e dos ombros, que é onde o olho
	-- está. Saindo de baixo, ela ficava atrás do sprite e só aparecia nos pés.
	attachment.Position = Vector3.new(0, SPRITE_HEIGHT * 0.2, 0)
	attachment.Parent = part

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Emitter"
	emitter.Enabled = false -- só solta em rajada, nunca contínuo
	emitter.Rate = 0
	emitter.LightEmission = 0.65
	emitter.LightInfluence = 0
	emitter.Parent = attachment
	return emitter
end

-- O corte usa emissor SEPARADO do das partículas: ele liga o modo flipbook, e
-- reaproveitar o mesmo objeto obrigaria a desligar meia dúzia de propriedades a
-- cada troca — uma sobra qualquer entre um efeito e outro e o desenho sai errado.
local function EnsureFlipbook(hero)
	local part = hero.part
	if not (part and part.Parent) then return nil end

	local attachment = part:FindFirstChild("SkillSlash")
	if attachment then return attachment:FindFirstChild("Emitter") end

	attachment = Instance.new("Attachment")
	attachment.Name = "SkillSlash"
	attachment.Position = Vector3.new(0, SPRITE_HEIGHT * 0.1, 0)
	attachment.Parent = part

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Emitter"
	emitter.Enabled = false
	emitter.Rate = 0
	emitter.Speed = NumberRange.new(0, 0) -- fica parado em cima do alvo
	emitter.Rotation = NumberRange.new(0, 0)
	emitter.RotSpeed = NumberRange.new(0, 0)
	emitter.SpreadAngle = Vector2.new(0, 0)
	emitter.Drag = 0
	emitter.Acceleration = Vector3.zero
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	emitter.Color = ColorSequence.new(Color3.new(1, 1, 1))
	emitter.Transparency = NumberSequence.new(0)
	emitter.Orientation = Enum.ParticleOrientation.FacingCamera
	emitter.FlipbookMode = Enum.ParticleFlipbookMode.OneShot

	-- puxa o desenho na direção da câmera: o herói é um BillboardGui plantado na
	-- mesma casa, e sem isso o corte sairia ATRÁS do boneco que ele acabou de
	-- cortar (foi o que aconteceu com as partículas antes de crescerem)
	emitter.ZOffset = 2
	emitter.Parent = attachment
	return emitter
end

function HeroView.PlaySkillEffect(hero, key)
	local slash = FLIPBOOK_EFFECTS[key]
	if slash then
		local emitter = EnsureFlipbook(hero)
		if not emitter then return end

		emitter.Texture = slash.texture
		emitter.FlipbookLayout = slash.layout
		emitter.FlipbookFramerate = NumberRange.new(slash.framerate, slash.framerate)
		emitter.Lifetime = NumberRange.new(slash.lifetime, slash.lifetime)
		emitter.Size = NumberSequence.new(slash.size)
		emitter:Emit(1)
		return
	end

	local spec = SKILL_EFFECTS[key]
	if not spec then return end

	local emitter = EnsureEmitter(hero)
	if not emitter then return end

	local rise = spec.shape == "rise"

	emitter.Texture = spec.texture
	emitter.Color = ColorSequence.new(spec.color)
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, spec.size),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Lifetime = NumberRange.new(0.4, 0.85)
	emitter.Speed = NumberRange.new(spec.speed * 0.55, spec.speed)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-140, 140)
	emitter.Drag = rise and 2 or 3.5

	-- subindo: jato estreito pra cima que desacelera; impacto: esfera pra todo
	-- lado que cai. É o que separa "ganhei alguma coisa" de "levei uma pancada".
	emitter.EmissionDirection = rise and Enum.NormalId.Top or Enum.NormalId.Front
	emitter.SpreadAngle = rise and Vector2.new(28, 28) or Vector2.new(180, 180)
	emitter.Acceleration = rise and Vector3.new(0, 7, 0) or Vector3.new(0, -7, 0)

	emitter:Emit(spec.count)
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

-- ===== BARRIL =====
-- O asset (130205426920176) é um Model com um MeshPart dentro. Aqui ele é
-- remontado como Part + SpecialMesh a partir da malha e da textura dele: assim o
-- barril nasce por código, versionado junto com o resto, sem depender de um
-- modelo guardado no place — que não entra no Rojo nem no git.
--
-- A malha nasce com ~3,0 x 3,6 studs. A casa mede ~9,8 de ponta a ponta e o
-- herói desenhado tem ~8 de altura: sem ampliar, o barril viraria um pontinho no
-- meio do hexágono. 1,45 deixa ele com pouco mais de 5 de altura — objeto de
-- cenário que dá pra acertar, sem competir com o herói.
local BARREL_MESH = "rbxassetid://119956806509588"
local BARREL_TEXTURE = "rbxassetid://137018550249951"
local BARREL_NATIVE = Vector3.new(3.011, 3.583, 3.011)
local BARREL_SCALE = 1.45

local BARREL_DUST = Color3.fromRGB(196, 150, 96)

local function BarrelCFrame(barrel)
	local size = BARREL_NATIVE * BARREL_SCALE
	return GroundCFrame(barrel.position, barrel.view.origin) * CFrame.new(0, size.Y / 2, 0)
end

-- ===== VIDA DO BARRIL =====
-- Um quadradinho por golpe que ele ainda aguenta, na mesma casca escura com
-- moldura dourada dos crachás de herói. Bolinhas e não número porque a vida do
-- barril não é vida: são DUAS pancadas, e duas pecinhas se leem sem contar.
-- Apaga da direita pra esquerda conforme apanha.
local BARREL_PIP_ON = Color3.fromRGB(232, 172, 74) -- o mesmo âmbar que o cliente pinta na casa
local BARREL_PIP_OFF = Color3.fromRGB(64, 54, 44)
local BARREL_PIP = 9

local function BuildBarrelBadge(part, barrel)
	local gui = Instance.new("BillboardGui")
	gui.Name = "BarrelInfo"
	gui.Size = UDim2.new(0, barrel.hitsLeft * (BARREL_PIP + 3) + 7, 0, BARREL_PIP + 8)
	gui.StudsOffset = Vector3.new(0, (BARREL_NATIVE.Y * BARREL_SCALE) * 0.72, 0)
	-- sem AlwaysOnTop: nada fica na frente do barril no tabuleiro, e assim ele
	-- não atravessa cenário nem rouba o clique de quem estiver atrás
	gui.Parent = part

	local shell = Instance.new("Frame")
	shell.Name = "Shell"
	shell.Size = UDim2.fromScale(1, 1)
	shell.BackgroundColor3 = BADGE_BG
	shell.BorderSizePixel = 0
	shell.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = shell

	local stroke = Instance.new("UIStroke")
	stroke.Color = BADGE_GOLD
	stroke.Thickness = 1.1
	stroke.Transparency = 0.15
	stroke.Parent = shell

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 3)
	layout.Parent = shell

	for index = 1, barrel.hitsLeft do
		local pip = Instance.new("Frame")
		pip.Name = "Pip" .. index
		pip.LayoutOrder = index
		pip.Size = UDim2.new(0, BARREL_PIP, 0, BARREL_PIP)
		pip.BackgroundColor3 = BARREL_PIP_ON
		pip.BorderSizePixel = 0
		pip.Parent = shell

		local pipCorner = Instance.new("UICorner")
		pipCorner.CornerRadius = UDim.new(0, 2)
		pipCorner.Parent = pip
	end

	return gui
end

function HeroView.UpdateBarrelBadge(barrel)
	local part = barrel.part
	if not (part and part.Parent) then return end

	local gui = part:FindFirstChild("BarrelInfo")
	local shell = gui and gui:FindFirstChild("Shell")
	if not shell then return end

	for _, pip in ipairs(shell:GetChildren()) do
		local index = tonumber(pip.Name:match("^Pip(%d+)$") or "")
		if index then
			local aceso = index <= barrel.hitsLeft
			TweenService:Create(pip, TweenInfo.new(0.2), {
				BackgroundColor3 = aceso and BARREL_PIP_ON or BARREL_PIP_OFF,
			}):Play()
		end
	end
end

-- Rajada de lascas/poeira presa ao barril. Usada no golpe e na quebra.
local function BarrelBurst(part, count, speed)
	local attachment = part:FindFirstChild("Dust")
	if not attachment then
		attachment = Instance.new("Attachment")
		attachment.Name = "Dust"
		attachment.Parent = part

		local emitter = Instance.new("ParticleEmitter")
		emitter.Name = "Emitter"
		emitter.Enabled = false
		emitter.Rate = 0
		emitter.Texture = FX_SMOKE
		emitter.Color = ColorSequence.new(BARREL_DUST)
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.2),
			NumberSequenceKeypoint.new(1, 1),
		})
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 2.2),
			NumberSequenceKeypoint.new(1, 0),
		})
		emitter.Lifetime = NumberRange.new(0.35, 0.8)
		emitter.Rotation = NumberRange.new(0, 360)
		emitter.RotSpeed = NumberRange.new(-160, 160)
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.Acceleration = Vector3.new(0, -12, 0)
		emitter.Drag = 3
		emitter.LightEmission = 0.2
		emitter.Parent = attachment
	end

	local emitter = attachment:FindFirstChild("Emitter")
	if emitter then
		emitter.Speed = NumberRange.new(speed * 0.5, speed)
		emitter:Emit(count)
	end
end

function HeroView.CreateBarrel(barrel)
	local size = BARREL_NATIVE * BARREL_SCALE

	local part = Instance.new("Part")
	part.Name = "Barrel_" .. barrel.uid
	-- A caixa é o que recebe o clique; quem aparece é a malha, que substitui a
	-- geometria do bloco. NÃO adianta pôr Transparency em 1 achando que esconde
	-- só o bloco: com SpecialMesh a transparência da peça vale pro desenho todo e
	-- o barril fica invisível (foi o primeiro erro desta função).
	part.Size = size
	part.Transparency = 0
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = true
	part.CFrame = BarrelCFrame(barrel)
	part:SetAttribute("BarrelUid", barrel.uid)
	part.Parent = barrel.view.heroesFolder

	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.FileMesh
	mesh.MeshId = BARREL_MESH
	mesh.TextureId = BARREL_TEXTURE
	mesh.Scale = Vector3.new(BARREL_SCALE, BARREL_SCALE, BARREL_SCALE)
	mesh.Parent = part

	BuildBarrelBadge(part, barrel)

	barrel.part = part
	return part
end

-- Primeiro golpe: apaga um quadradinho do crachá, sacode, solta poeira e fica
-- TORTO até a próxima pancada. A inclinação é redundante com o crachá de
-- propósito: o barril fica óbvio mesmo pra quem está com a câmera longe.
function HeroView.PlayBarrelHit(barrel)
	local part = barrel.part
	if not (part and part.Parent) then return end

	PlaySound("Hit", barrel.view)
	BarrelBurst(part, 10, 9)
	HeroView.UpdateBarrelBadge(barrel)

	local base = BarrelCFrame(barrel)
	local tombado = base * CFrame.Angles(math.rad(9), 0, math.rad(13))
	local repouso = (barrel.hitsLeft <= 1) and tombado or base

	TweenService:Create(part, TweenInfo.new(0.08, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		CFrame = base * CFrame.new(0, 0.5, 0) * CFrame.Angles(math.rad(-12), 0, math.rad(10)),
	}):Play()

	task.delay(0.1, function()
		if part.Parent then
			TweenService:Create(part, TweenInfo.new(0.2, Enum.EasingStyle.Quad), { CFrame = repouso }):Play()
		end
	end)
end

function HeroView.BreakBarrel(barrel)
	local part = barrel.part
	barrel.part = nil
	if not (part and part.Parent) then return end

	-- Som próprio, e não o HeroDeath: barril quebrando é madeira estourando, não
	-- alguém morrendo. Emprestar o som de morte fazia o jogador olhar pro
	-- tabuleiro procurando qual herói tinha caído.
	PlaySound("BarrelBreak", barrel.view)
	BarrelBurst(part, 30, 20)

	-- o crachá some junto com o barril, não com o Part: ele ainda vive ~1s pra
	-- as partículas terminarem, e um placar de vida boiando sobre os cacos seria
	-- a única coisa na tela dizendo que ainda tem barril ali
	local badge = part:FindFirstChild("BarrelInfo")
	if badge then badge.Enabled = false end

	-- o barril some rápido, mas o Part só é destruído depois: destruir na hora
	-- levaria as partículas junto e a quebra não apareceria
	local mesh = part:FindFirstChildWhichIsA("SpecialMesh")
	if mesh then
		TweenService:Create(mesh, TweenInfo.new(0.25), { Scale = Vector3.new(0.1, 0.1, 0.1) }):Play()
	end
	part.CanQuery = false
	Debris:AddItem(part, 1.2)
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

	-- descarta o que ficou pra trás: mensagem velha exibida fora de hora engana
	-- mais do que informa, porque o jogador lê o número olhando pro golpe atual
	while #sayQueue[uid] > BUBBLE_QUEUE_MAX do
		table.remove(sayQueue[uid], 1)
	end

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

	-- por herói, não global: quem veio depois da folha tem asset próprio
	local spriteId = HeroData.GetSpriteId(data)

	if spriteId then
		local spriteGui = Instance.new("BillboardGui")
		spriteGui.Name = "Sprite"
		spriteGui.Size = UDim2.new(
			SPRITE_WIDTH, SPRITE_PIXEL_FLOOR_W,
			SPRITE_HEIGHT, SPRITE_PIXEL_FLOOR_H)
		-- referência no topo da casa; o SizeOffset sobe meio sprite a partir
		-- dali, então os pés ficam plantados seja qual for o tamanho desenhado
		spriteGui.StudsOffsetWorldSpace = Vector3.new(0, -ANCHOR_LIFT, 0)
		spriteGui.SizeOffset = Vector2.new(0, 0.5)
		-- só profundidade, pra ganhar do próprio crachá no empate (ver
		-- SPRITE_DEPTH_BIAS). O plantar dos pés continua a cargo das duas linhas
		-- acima, que são world-space e não mudam.
		spriteGui.StudsOffset = Vector3.new(0, 0, SPRITE_DEPTH_BIAS)
		spriteGui.LightInfluence = 0
		spriteGui.Parent = anchor

		local image = Instance.new("ImageLabel")
		image.Name = "Frame"
		image.Size = UDim2.fromScale(1, 1)
		image.BackgroundTransparency = 1
		image.Image = spriteId
		image.ImageRectSize = HeroData.GetFrameSize(data)
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
	-- Precisa caber o MAIOR corpo de TEXT_STYLES com folga: o TextLabel ocupa a
	-- caixa inteira e o Roblox recorta o que passar dela. Com os 38px antigos e
	-- a fonte de dano em 44, o número sairia decapitado.
	bubble.Size = UDim2.new(0, 240, 0, 58)
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

	-- A caixa é larga o bastante pro pior caso (ataque + vida + passiva + veneno +
	-- gelo); o UIListLayout centraliza o que existir, então herói sem passiva
	-- continua com o crachá curtinho e centrado.
	local statsGui = Instance.new("BillboardGui")
	statsGui.Name = "HeroInfo"
	statsGui.Size = UDim2.new(0, 148, 0, BADGE_HEIGHT + 2)
	statsGui.StudsOffset = Vector3.new(0, -SPRITE_HEIGHT * 0.34, 0)
	-- SEM AlwaysOnTop: é o que tirava o crachá da fila de profundidade e o fazia
	-- passar por cima do próprio herói, dos outros heróis e do cenário. Ver o
	-- bloco SPRITE_DEPTH_BIAS lá em cima pra hierarquia completa.
	statsGui.AlwaysOnTop = false
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

	-- Gelo do Kor: mesma casca dos outros selos, com o floco desenhado (PixelIcons)
	-- em vez de tira de imagem. Montado uma vez; o UpdateStats só liga e desliga.
	local chill = shell("Chill", SQUARE_BADGE_WIDTH, 6)
	chill.Visible = false

	local chillSlot = Instance.new("Frame")
	chillSlot.Name = "Slot"
	chillSlot.AnchorPoint = Vector2.new(0.5, 0.5)
	chillSlot.Position = UDim2.fromScale(0.5, 0.5)
	chillSlot.Size = UDim2.new(0, ICON_SLOT, 0, ICON_SLOT)
	chillSlot.BackgroundTransparency = 1
	chillSlot.ZIndex = 2
	chillSlot.Parent = chill

	PixelIcons.Build("freeze", chillSlot, FREEZE_ICON_COLOR, 2)

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
	local chill = row:FindFirstChild("Chill")

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

	if chill then
		local frozen = false
		for _, effect in ipairs(hero.statusEffects) do
			if effect.type == "freeze" then frozen = true end
		end
		chill.Visible = frozen
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
-- `silent` corta só o SOM, nunca o desenho. Serve pro dano sem autor (veneno,
-- morte súbita), que acontece em vários heróis ao mesmo tempo: o clarão vermelho
-- é por herói e continua legível empilhado, mas seis "Hit" disparados no mesmo
-- quadro viram um estouro só e fazem a virada de turno soar como engasgo.
function HeroView.PlayAnimation(hero, animationName, silent)
	if not hero.part or not hero.part.Parent then return end

	local spriteGui = hero.part:FindFirstChild("Sprite")
	local image = spriteGui and spriteGui:FindFirstChild("Frame")

	if animationName == "hit" then
		if image then
			image.ImageColor3 = Color3.fromRGB(255, 110, 110)
			TweenService:Create(image, TweenInfo.new(0.35), { ImageColor3 = Color3.new(1, 1, 1) }):Play()
		end
		if not silent then PlaySound("Hit", hero.view) end

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
	-- O giro entra ANTES de qualquer coisa presa à lápide: o topo arredondado e a
	-- etiqueta do nome são montados a partir deste CFrame, então acompanham
	-- sozinhos e continuam encaixados por mais que o ângulo mude.
	stone.CFrame = GroundCFrame(hero.position, hero.view.origin)
		* CFrame.new(0, 1.5, 0)
		* CFrame.Angles(0, math.rad(GRAVE_YAW), 0)
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
