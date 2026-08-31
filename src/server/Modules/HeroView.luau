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
local InsertService = game:GetService("InsertService")

local HexGrid = require(ReplicatedStorage.Modules.HexGrid)
local HeroData = require(ReplicatedStorage.Modules.HeroData)
local PixelIcons = require(ReplicatedStorage.Modules.PixelIcons)
local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local Arenas = require(ReplicatedStorage.Modules.Arenas)

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

local HERO_GUI_MAX_DISTANCE = 200
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

-- ===== PÉS PLANTADOS COM ScaleType.Fit =====
-- O SizeOffset lá embaixo planta na casa o pé da MOLDURA. Só que o Fit
-- centraliza a arte DENTRO da moldura (ver HeroData.GetArtAspect): arte mais
-- larga que a moldura 165x231 deixa faixa vazia em cima e embaixo, e a de baixo
-- deixa o desenho boiando no ar. Não é sutil — o Golem é quase o dobro de largo
-- que a moldura e perdia 21% da altura do quadro só nisso (~2,4 studs). E a
-- faixa cresce junto com o `scale`, então ampliá-lo piorou o problema.
--
-- Fit não aceita alinhamento ("encosta embaixo" não existe), então descontamos a
-- faixa na mão. Em FRAÇÃO, igual ao 0,5 que ela corrige: assim acompanha o zoom
-- (a moldura muda de tamanho com a distância, ver PISO EM PIXELS) e o `scale`
-- de graça, sem recalcular nada.
local FRAME_ASPECT = HeroData.FRAME_WIDTH / HeroData.FRAME_HEIGHT

local function FootSizeOffset(data)
	-- altura desenhada / altura da moldura. Dá 1 para arte mais alta que a
	-- moldura: aí o Fit limita pela altura e não sobra faixa nenhuma.
	local drawn = math.min(1, FRAME_ASPECT / HeroData.GetArtAspect(data))
	return 0.5 - (1 - drawn) / 2
end

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
	-- Lucy — dano que o emberShield dela absorveu por um aliado perto. Violeta
	-- de propósito: não é "damage" (vermelho, ela não tomou o golpe) nem "heal"
	-- (verde, não é vida entrando) — é a terceira coisa, dano que deixou de
	-- acontecer. Mesmo corpo/animação/tempo dos outros, só a cor muda.
	absorb = { color = Color3.fromRGB(190, 160, 255), font = Enum.Font.GothamBlack,  size = 34, rise = 2.8 },
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

-- ===== HERÓI INVISÍVEL NÃO EMITE NADA =====
-- Esconder o boneco não bastava: partícula, balão de dano/cura e som próprio
-- nascem NO SERVIDOR e chegam iguais aos dois clientes, então a fumacinha da
-- Sombra Densa entregava, todo fim de turno, a casa exata onde o Nash tinha
-- parado. O adversário não via o herói e sabia onde ele estava.
--
-- O filtro fica aqui, na porta de saída do visual, e não em cada skill: assim
-- vale pra qualquer efeito de qualquer habilidade, inclusive as que ainda não
-- existem. Quem quebra a invisibilidade (atacar, apanhar) apaga a marca ANTES
-- de pedir o efeito da quebra — é por isso que a revelação continua aparecendo.
local function Hidden(hero)
	return hero ~= nil and hero.stealth == true
end

function HeroView.PlayAttackSound(hero)
	if hero.attackSound then
		PlaySound(hero.attackSound, hero.view)
		return
	end

	-- Por HABILIDADE, não por nome: nome de herói pode mudar (Shadow virou
	-- Nash no meio do projeto) e quebraria esta checagem em silêncio. Blade,
	-- Kor e Dante continuam por nome porque são anteriores a essa lição — sem
	-- problema tocar neles de novo, só não repetir o erro nos novos.
	if hero.name == "Blade" then
		PlaySound("SwordSwing", hero.view)
	elseif hero.name == "Kor" then
		PlaySound("IceSwing", hero.view)
	elseif hero.name == "Dante" then
		PlaySound("arrowSwing", hero.view)
	elseif table.find(hero.abilities, "raiseSkulls") then
		PlaySound("SoulPull", hero.view)
	elseif table.find(hero.abilities, "poisonAttack") then
		PlaySound("PoisonHiss", hero.view)
	elseif table.find(hero.abilities, "flameStrike") then
		PlaySound("FlameSwing", hero.view) -- Karo
	elseif table.find(hero.abilities, "ambush") then
		PlaySound("DaggerSwing", hero.view) -- Nash
	elseif table.find(hero.abilities, "gustPush") then
		PlaySound("WindSwing", hero.view) -- Zeff
	elseif table.find(hero.abilities, "longShot") then
		PlaySound("RifleShot", hero.view) -- Wren
	end
end

function HeroView.PlayHealSound(hero)
	if Hidden(hero) then return end
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
	clean = "SkillClean",
	gustPush = "SkillGust", -- Zeff

	-- Ainda sem asset próprio. O PlaySound sai calado quando o som não existe em
	-- ReplicatedStorage.Sounds, então isto é o gancho pronto pro dia em que o
	-- arquivo entrar — e não um erro esperando acontecer.
	ambush = "SkillAmbush",
	stealth = "SkillStealth", -- Nash: entrando na sombra
	shatter = "SkillShatter", -- Golem: partindo em dois
	iceStorm = "SkillIceStorm", -- Kor: a nevasca da morte dele
	estopim = "SkillEstopim",
	raiseSkulls = "SkillRaiseSkulls",
	dodge = "SkillDodge",
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
	poisonFlask   = { color = Color3.fromRGB(150, 245, 110), texture = FX_SMOKE, shape = "burst", count = 20, size = 2.4, speed = 12 },
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

	-- ===== KARO =====
	-- O rastro é discreto: ele acontece a cada passo do Karo, e a chama que fica
	-- na casa (CreateFlame) já é o efeito principal. Fumaça grande aqui
	-- competiria com ela e apagaria a leitura do próprio caminho.
	-- Reaproveitado pelo Furor das Chamas (Skills.flameFury) além do próprio
	-- rastro — "rise" combina com os dois: deixar fogo no chão e carregar
	-- energia pisando nele de novo.
	flamePath     = { color = Color3.fromRGB(255, 150, 70),  texture = FX_SMOKE, shape = "rise",  count = 10, size = 2.0, speed = 5 },
	flameStrike   = { color = Color3.fromRGB(255, 120, 50),  texture = FX_SMOKE, shape = "burst", count = 26, size = 3.2, speed = 18 },

	-- ===== SHADOW =====
	-- Sumir é fumaça escura que SOBE e fecha; aparecer é a mesma cor estourando
	-- pra fora. As duas juntas contam a história do vulto sem precisar de texto.
	stealth       = { color = Color3.fromRGB(60, 60, 90),    texture = FX_SMOKE, shape = "rise",  count = 20, size = 2.8, speed = 7 },
	stealthBreak  = { color = Color3.fromRGB(90, 90, 130),   texture = FX_SMOKE, shape = "burst", count = 22, size = 2.8, speed = 14 },
	stealthHeal   = { color = Color3.fromRGB(130, 150, 220), texture = FX_SPARK, shape = "rise",  count = 14, size = 2.0, speed = 7 },

	-- a emboscada é o golpe que define o herói: estoura roxo, bem visível
	ambush        = { color = Color3.fromRGB(170, 110, 255), texture = FX_SPARK, shape = "burst", count = 30, size = 2.8, speed = 19 },

	-- ===== GOLEM =====
	-- Estilhaçar é a morte dele virando duas peças novas: pedra pra todo lado,
	-- no mesmo peso da Tempestade de Gelo do Kor (o outro "morri e algo grande
	-- acontece" do elenco).
	shatter       = { color = Color3.fromRGB(150, 145, 135), texture = FX_SMOKE, shape = "burst", count = 40, size = 3.4, speed = 22 },

	-- ===== ZEFF =====
	-- A Rajada estoura na hora do golpe — mesmo peso do brokenDefense/
	-- iceEffect, é o empurrão acontecendo, não uma cura ou buff carregando.
	gustPush = { color = Color3.fromRGB(150, 235, 220), texture = FX_SPARK, shape = "burst", count = 20, size = 2.6, speed = 15 },

	-- rastro de vento a cada passo: discreto de propósito, mesmo raciocínio do
	-- bloodScent do Merlin — dispara TODO passo, não pode competir com o golpe
	windStep      = { color = Color3.fromRGB(170, 235, 225), texture = FX_SMOKE, shape = "rise",  count = 8,  size = 1.8, speed = 5 },
	momentum      = { color = Color3.fromRGB(90, 180, 255),   texture = FX_SPARK, shape = "rise",  count = 10, size = 2.0, speed = 11 },
	dodge         = { color = Color3.fromRGB(150, 220, 255),  texture = FX_SPARK, shape = "burst", count = 26, size = 2.2, speed = 22 },
	voltChain     = { color = Color3.fromRGB(255, 226, 90),  texture = FX_SPARK, shape = "burst", count = 16, size = 1.8, speed = 18 },
	tailwind      = { color = Color3.fromRGB(190, 250, 240), texture = FX_SPARK, shape = "rise",  count = 16, size = 2.2, speed = 9 },

	-- ===== WREN =====
	-- Estoura NO ALVO (é lá que a skill chama o Effect), não nela: o tiro dela
	-- já tem a bolinha do ShowRangedAttack cruzando o tabuleiro, e o que falta
	-- é a marca do impacto na outra ponta. Verde-espectral, a cor dela.
	longShot = { color = Color3.fromRGB(120, 225, 190), texture = FX_SPARK, shape = "burst", count = 24, size = 2.6, speed = 17 },

	raiseSkulls = { color = Color3.fromRGB(120, 245, 110), texture = FX_SMOKE, shape = "rise",  count = 24, size = 2.8, speed = 8 },
	estopim     = { color = Color3.fromRGB(150, 255, 120), texture = FX_SMOKE, shape = "burst", count = 32, size = 3.2, speed = 20 },
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

function HeroView.PlaySkillEffect(hero, key, boost)
	if Hidden(hero) then return end

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

	emitter:Emit(math.floor(spec.count * (boost or 1)))
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
local function GetFolder(name, matchId)
	local folder = Workspace:FindFirstChild(name)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = Workspace
	end
	folder:SetAttribute("MatchId", matchId)
	return folder
end

-- Cada partida tem suas pastas e sua origem no mundo. Chamada uma vez pelo
-- MatchManager; o resultado vive em match.view e em hero.view.
function HeroView.CreateView(matchId, origin, players, theme)
	return {
		id = matchId,
		origin = origin,
		players = players,
		theme = theme,
		heroesFolder = GetFolder("Heroes_" .. matchId, matchId),
		gravesFolder = GetFolder("Graves_" .. matchId, matchId),
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

-- O objeto neutro muda de cara com a arena (ver Arenas): barril na clareira,
-- bloco de gelo na geleira, urna no santuário. A REGRA é a mesma — mesma
-- contagem de golpes, mesma casa ocupada, mesmo prêmio. Sem tema (simulação de
-- balanceamento, partida antiga) cai no barril de sempre.
local function ObjectSpec(view)
	return view and view.theme and view.theme.object or nil
end

-- Asset do catálogo, carregado UMA vez e guardado fora da DataModel pra ser
-- clonado a cada objeto. Antes eu só extraía MeshId/textura pra remontar como
-- Part + SpecialMesh, e isso só funciona pra asset que É uma malha: o cristal
-- do gelo é um Model de Parts, então não sobrava nada e o tema caía no cubo de
-- reserva. Agora vale qualquer modelo — Part, Union ou MeshPart.
--
-- Falhou o carregamento (asset privado, sem rede), o tema usa o `part` de
-- reserva e a partida segue: objeto invisível no tabuleiro seria bem pior.
local assetModelCache = {}

local function ModelFromAsset(assetId)
	if assetModelCache[assetId] ~= nil then
		return assetModelCache[assetId] or nil
	end

	local ok, container = pcall(function()
		return InsertService:LoadAsset(assetId)
	end)

	local template = false
	if ok and container then
		local found = container:FindFirstChildWhichIsA("Model") or container:FindFirstChildWhichIsA("BasePart")

		if found and found:IsA("BasePart") then
			local wrapper = Instance.new("Model")
			found.Parent = wrapper
			found = wrapper
		end

		if found and found:FindFirstChildWhichIsA("BasePart", true) then
			-- Modelo do catálogo é código de terceiro. Fica só a geometria: script
			-- dentro de modelo grátis é o vetor de backdoor mais antigo do Roblox, e
			-- este aqui roda no SERVIDOR.
			for _, descendant in ipairs(found:GetDescendants()) do
				if descendant:IsA("LuaSourceContainer") then descendant:Destroy() end
			end

			-- Parent nil, e não Destroy no container: o molde segue vivo pela
			-- referência aqui, fora da árvore, sem replicar pra ninguém.
			found.Parent = nil
			template = found
		end

		container:Destroy()
	end

	if not template then
		warn(("HeroView: nao consegui carregar o modelo do asset %s — objeto do board no visual de reserva.")
			:format(tostring(assetId)))
	end

	assetModelCache[assetId] = template
	return template or nil
end

local function AssetVisual(assetId, height, skin)
	if not assetId then return nil end

	local template = ModelFromAsset(assetId)
	if not template then return nil end

	local extents = template:GetExtentsSize()
	local scale = height and (height / math.max(extents.Y, 0.001)) or 1
	return { model = template, scale = scale, size = extents * scale, skin = skin }
end

local function ObjectVisual(view)
	local spec = ObjectSpec(view)
	if not spec then return nil end

	local visual = AssetVisual(spec.asset, spec.height, spec.skin)
	if visual then return visual end

	local fallback = Arenas.DEFAULT_OBJECT
	if fallback then
		visual = AssetVisual(fallback.asset, spec.height or fallback.height, spec.skin or fallback.skin)
		if visual then return visual end
	end

	if spec.mesh then return { mesh = spec.mesh } end
	if spec.part then return { part = spec.part } end
	return nil
end

local function ObjectSize(barrel)
	local visual = ObjectVisual(barrel.view)
	if visual then
		if visual.model then return visual.size end
		if visual.mesh then return visual.mesh.native * visual.mesh.scale end
		if visual.part then return visual.part.size end
	end
	return BARREL_NATIVE * BARREL_SCALE
end

local function ObjectDust(view)
	local spec = ObjectSpec(view)
	return spec and spec.dust or BARREL_DUST
end

-- Gelo não estala como madeira. O tema pede o som pelo NOME, e o nome tem que
-- existir em ReplicatedStorage.Sounds — os áudios são do place, como todos os
-- outros. Faltando, cai no som do barril e avisa UMA vez por nome: silêncio
-- seria pior, e um aviso por pancada seria spam.
local warnedSounds = {}

local function ObjectSound(view, key, fallback)
	local spec = ObjectSpec(view)
	local name = spec and spec[key]
	if not name then return fallback end

	if Sounds:FindFirstChild(name) then return name end

	if not warnedSounds[name] then
		warnedSounds[name] = true
		warn(("HeroView: som '%s' nao existe em ReplicatedStorage.Sounds — usando '%s'.")
			:format(name, fallback))
	end

	return fallback
end

local function IsLyingCylinder(barrel)
	local visual = ObjectVisual(barrel.view)
	return visual ~= nil and visual.part ~= nil and visual.part.shape == Enum.PartType.Cylinder
end

local function BarrelCFrame(barrel)
	local size = ObjectSize(barrel)
	local base = GroundCFrame(barrel.position, barrel.view.origin) * CFrame.new(0, size.Y / 2, 0)

	-- Part cilíndrica do Roblox nasce deitada no eixo X: a rotação entra na CFrame
	-- BASE pra sobreviver aos tweens de pancada.
	if IsLyingCylinder(barrel) then
		base = base * CFrame.Angles(0, 0, math.rad(90))
	end

	return base
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
	gui.MaxDistance = HERO_GUI_MAX_DISTANCE
	gui.Name = "BarrelInfo"
	gui.Size = UDim2.new(0, barrel.hitsLeft * (BARREL_PIP + 3) + 7, 0, BARREL_PIP + 8)
	gui.StudsOffset = Vector3.new(0, ObjectSize(barrel).Y * 0.72, 0)
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
local function BarrelBurst(part, count, speed, color)
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
		emitter.Color = ColorSequence.new(color or BARREL_DUST)
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

-- Modelo de catálogo vem com a aparência de quem o publicou — o cristal do gelo
-- é uma Union PRETA, e Union ignora Color enquanto UsePartColor for falso. Aqui
-- ele veste a pele do tema: cor, material e brilho do gelo, sem textura de
-- terceiro por cima. Sem `skin` no tema, o modelo fica como veio.
local function PaintSkin(part, skin)
	if part:IsA("UnionOperation") then part.UsePartColor = true end
	if part:IsA("MeshPart") then part.TextureID = "" end

	for _, child in ipairs(part:GetChildren()) do
		if child:IsA("SurfaceAppearance") or child:IsA("Decal") then child:Destroy() end
	end

	if skin.color then part.Color = skin.color end
	if skin.material then part.Material = skin.material end
	part.Transparency = skin.transparency or 0
	part.Reflectance = skin.reflectance or 0
end

-- O modelo do asset vira FILHO da caixa: as peças dele ficam sem âncora e
-- soldadas nela, que é o que faz o conjunto inteiro acompanhar os tweens de
-- pancada (a caixa é a raiz ancorada da montagem). Sem colisão e sem query: quem
-- recebe o clique é a caixa, senão o golpe acertaria uma quina do cristal e o
-- cliente não acharia o BarrelUid.
local function AttachObjectModel(part, visual)
	local model = visual.model:Clone()
	model.Name = "ObjectModel"
	model.Parent = part

	if math.abs(visual.scale - 1) > 0.01 then
		model:ScaleTo(visual.scale)
	end

	-- leva o CENTRO da caixa delimitadora até a caixa de clique; o pivô do
	-- modelo pode estar em qualquer canto, e usá-lo direto enterraria metade do
	-- cristal no chão
	local boxCFrame = model:GetBoundingBox()
	model:PivotTo((part.CFrame * boxCFrame:Inverse()) * model:GetPivot())

	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.Massless = true
			descendant.CastShadow = false

			if visual.skin then PaintSkin(descendant, visual.skin) end

			local weld = Instance.new("WeldConstraint")
			weld.Part0 = part
			weld.Part1 = descendant
			weld.Parent = descendant
		end
	end

	return model
end

function HeroView.CreateBarrel(barrel)
	local visual = ObjectVisual(barrel.view)
	local size = ObjectSize(barrel)

	local part = Instance.new("Part")
	part.Name = "Barrel_" .. barrel.uid
	-- A caixa é o que recebe o clique. Na arena que usa MALHA é ela quem aparece:
	-- NÃO adianta pôr Transparency em 1 achando que esconde só o bloco — com
	-- SpecialMesh a transparência vale pro desenho todo e o objeto some.
	part.Size = IsLyingCylinder(barrel) and Vector3.new(size.Y, size.X, size.Z) or size
	part.Transparency = 0
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = true
	part.CFrame = BarrelCFrame(barrel)
	part:SetAttribute("BarrelUid", barrel.uid)
	part.Parent = barrel.view.heroesFolder

	if visual and visual.model then
		part.Transparency = 1
		AttachObjectModel(part, visual)
	elseif visual and visual.part then
		part.Shape = visual.part.shape or Enum.PartType.Block
		part.Color = visual.part.color
		part.Material = visual.part.material
		part.Transparency = visual.part.transparency or 0
		part.Reflectance = visual.part.reflectance or 0
	else
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.FileMesh
		mesh.MeshId = (visual and visual.mesh and visual.mesh.id) or BARREL_MESH
		mesh.TextureId = (visual and visual.mesh and visual.mesh.texture) or BARREL_TEXTURE
		local scale = (visual and visual.mesh and visual.mesh.scale) or BARREL_SCALE
		mesh.Scale = Vector3.new(scale, scale, scale)
		mesh.Parent = part
	end

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

	PlaySound(ObjectSound(barrel.view, "hitSound", "Hit"), barrel.view)
	BarrelBurst(part, 10, 9, ObjectDust(barrel.view))
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
	PlaySound(ObjectSound(barrel.view, "breakSound", "BarrelBreak"), barrel.view)
	BarrelBurst(part, 30, 20, ObjectDust(barrel.view))

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

	-- Modelo do asset some por transparência, não por escala: as peças estão
	-- soldadas, e encolher briga com a solda.
	local model = part:FindFirstChild("ObjectModel")
	if model then
		for _, descendant in ipairs(model:GetDescendants()) do
			if descendant:IsA("BasePart") then
				TweenService:Create(descendant, TweenInfo.new(0.25), { Transparency = 1 }):Play()
			end
		end
	end
	part.CanQuery = false
	Debris:AddItem(part, 1.2)
end

-- ===== FOGO NO CHÃO (Karo) =====
-- Nasce por código como o barril, e pelo mesmo motivo: nada que dependa de um
-- modelo guardado no place, que não entra no Rojo nem no git.
--
-- Vive na pasta de heróis da partida (não numa terceira pasta) porque o
-- ClearMatch já apaga aquela pasta inteira no fim do jogo — chama esquecida
-- queimando numa arena vazia seria um vazamento silencioso entre partidas.
--
-- O nome do Part carrega o hexId: é assim que o DestroyFlame acha a chama certa
-- sem o servidor ter que guardar uma segunda tabela de Parts em paralelo à
-- match.flames.
local FLAME_COLOR = Color3.fromRGB(255, 140, 60)
local FLAME_CORE = Color3.fromRGB(255, 225, 150)

local SideColor, AttachTo, BuildTeamRing

local function FlameName(hexId)
	return "Flame_" .. hexId
end

function HeroView.CreateFlame(view, hexId, sideIndex)
	if not view then return end

	local existing = view.heroesFolder:FindFirstChild(FlameName(hexId))
	if existing then existing:Destroy() end -- reacendeu a mesma casa: começa limpo

	local center = HexGrid.GetWorldPosition(hexId, view.origin)
	local size = HexGrid.GetHexSize()

	-- Âncora invisível e fina, rente ao topo da casa. O fogo em si é partícula:
	-- um bloco laranja sólido tamparia a casa e brigaria com a pintura de
	-- movimento que o cliente já faz por cima do tabuleiro.
	local part = Instance.new("Part")
	part.Name = FlameName(hexId)
	part.Size = Vector3.new(size * 0.9, 0.2, size * 0.9)
	part.CFrame = CFrame.new(center + Vector3.new(0, TILE_TOP_Y, 0))
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	-- CanQuery false: a chama não pode roubar o clique da casa embaixo dela, ou
	-- o jogador perderia a jogada tentando andar pro fogo.
	part.CanQuery = false
	part.CastShadow = false
	part.Parent = view.heroesFolder

	if sideIndex then
		BuildTeamRing(part, hexId, SideColor(sideIndex), view.origin)
	end

	local attachment = Instance.new("Attachment")
	attachment.Parent = part

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Emitter"
	emitter.Texture = FX_SMOKE
	emitter.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, FLAME_CORE),
		ColorSequenceKeypoint.new(1, FLAME_COLOR),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 2.4),
		NumberSequenceKeypoint.new(1, 0.2),
	})
	emitter.Lifetime = NumberRange.new(0.5, 0.9)
	emitter.Rate = 14
	emitter.Speed = NumberRange.new(3, 5.5)
	emitter.SpreadAngle = Vector2.new(18, 18)
	emitter.Acceleration = Vector3.new(0, 5, 0)
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-90, 90)
	emitter.LightEmission = 0.8
	emitter.LightInfluence = 0
	emitter.Parent = attachment

	local light = Instance.new("PointLight")
	light.Color = FLAME_COLOR
	light.Range = 10
	light.Brightness = 1.6
	light.Parent = part

	return part
end

function HeroView.DestroyFlame(view, hexId)
	if not view then return end

	local part = view.heroesFolder:FindFirstChild(FlameName(hexId))
	if not part then return end

	-- Para de EMITIR e só então destrói: apagar o Part na hora levaria junto as
	-- partículas ainda no ar, e a chama sumiria num corte seco.
	local emitter = part:FindFirstChildWhichIsA("ParticleEmitter", true)
	if emitter then emitter.Enabled = false end

	local light = part:FindFirstChildWhichIsA("PointLight")
	if light then
		TweenService:Create(light, TweenInfo.new(0.6), { Brightness = 0 }):Play()
	end

	Debris:AddItem(part, 1.2)
end

-- Quanto tempo o brilho de alcance do Karo fica na casa — só um telegraph
-- visual, não um efeito de jogo (não mora em match.flames, ninguém pisa
-- "nele"), então some rápido em vez dos 2 turnos do fogo de verdade.
local ATTACK_RANGE_FLASH_LIFETIME = 0.5

-- Karo: brilho rápido nas casas a distância 1 dele, sincronizado com o golpe
-- giratório do Soco de Chamas — mostra ONDE o golpe alcança antes/durante o
-- impacto, mesmo nas casas vazias que GetEnemiesInRange nem chega a marcar
-- (só quem está lá dentro leva efeito de acerto). Mesma construção do
-- CreateFlame (âncora fina rente ao topo da casa, mesma paleta laranja do
-- Karo) — pra ficar reconhecível como "o mesmo fogo dele", só que num pulso
-- só em vez de rastro persistente.
function HeroView.FlashAttackRange(view, hexIds, coreColor, edgeColor)
	if not view then return end

	local size = HexGrid.GetHexSize()
	coreColor = coreColor or FLAME_CORE
	edgeColor = edgeColor or FLAME_COLOR

	for _, hexId in ipairs(hexIds) do
		local center = HexGrid.GetWorldPosition(hexId, view.origin)

		local part = Instance.new("Part")
		part.Name = "RangeFlash_" .. hexId
		part.Size = Vector3.new(size * 0.9, 0.2, size * 0.9)
		part.CFrame = CFrame.new(center + Vector3.new(0, TILE_TOP_Y, 0))
		part.Transparency = 1
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false -- não pode roubar o clique da casa embaixo, mesma regra da chama
		part.CastShadow = false
		part.Parent = view.heroesFolder

		local attachment = Instance.new("Attachment")
		attachment.Parent = part

		local emitter = Instance.new("ParticleEmitter")
		emitter.Name = "Emitter"
		emitter.Texture = FX_SPARK
		emitter.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, coreColor),
			ColorSequenceKeypoint.new(1, edgeColor),
		})
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.2),
			NumberSequenceKeypoint.new(1, 1),
		})
		-- cresce pra preencher a casa e desaparece — o "anel" da área de
		-- alcance, não fumaça subindo (isso já é a linguagem visual do rastro)
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, size * 0.7),
			NumberSequenceKeypoint.new(1, size * 0.95),
		})
		emitter.Lifetime = NumberRange.new(ATTACK_RANGE_FLASH_LIFETIME, ATTACK_RANGE_FLASH_LIFETIME)
		emitter.Rate = 0
		emitter.Speed = NumberRange.new(0, 0)
		emitter.EmissionDirection = Enum.NormalId.Top
		emitter.LightEmission = 0.9
		emitter.LightInfluence = 0
		emitter.Parent = attachment
		emitter:Emit(1)

		Debris:AddItem(part, ATTACK_RANGE_FLASH_LIFETIME + 0.2)
	end
end

local POISON_CORE = Color3.fromRGB(196, 255, 150)
local POISON_EDGE = Color3.fromRGB(96, 200, 70)
local POISON_BOMB_TIME = 1.1

function HeroView.PlayPoisonBomb(view, hexId)
	if not view then return end

	local size = HexGrid.GetHexSize()
	local center = HexGrid.GetWorldPosition(hexId, view.origin)

	local hexIds = { hexId }
	for _, hex in ipairs(HexGrid.GetNeighbors(hexId)) do
		table.insert(hexIds, hex.id)
	end
	HeroView.FlashAttackRange(view, hexIds, POISON_CORE, POISON_EDGE)

	local cloud = Instance.new("Part")
	cloud.Name = "PoisonBomb"
	cloud.Shape = Enum.PartType.Ball
	cloud.Size = Vector3.new(size * 0.5, size * 0.5, size * 0.5)
	cloud.CFrame = CFrame.new(center + Vector3.new(0, TILE_TOP_Y + size * 0.4, 0))
	cloud.Color = POISON_CORE
	cloud.Material = Enum.Material.Neon
	cloud.Transparency = 0.45
	cloud.Anchored = true
	cloud.CanCollide = false
	cloud.CanQuery = false
	cloud.CastShadow = false
	cloud.Parent = view.heroesFolder

	local blast = size * 3.6
	TweenService:Create(cloud,
		TweenInfo.new(POISON_BOMB_TIME, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
			Size = Vector3.new(blast, blast, blast),
			Transparency = 1,
			Color = POISON_EDGE,
		}):Play()

	Debris:AddItem(cloud, POISON_BOMB_TIME + 0.15)
end

local ICE_CORE = Color3.fromRGB(236, 252, 255)
local ICE_EDGE = Color3.fromRGB(120, 200, 245)
local ICE_STORM_TIME = 0.7

local FIRE_CIRCLE_SOURCE = "Fire Circle"
local FIRE_CIRCLE_GROW = 0.22
local FIRE_CIRCLE_HOLD = 0.14
local FIRE_CIRCLE_CLOSE = 0.26
local FIRE_CIRCLE_SEED = 0.06
local FIRE_CIRCLE_TAIL = 1.6

local function SetEmitters(model, enabled)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then descendant.Enabled = enabled end
	end
end

local FIRE_CIRCLE_HOME = { "VFX", "Karo", "FireCircle" }
local FIRE_CIRCLE_LEGACY = { "Fire Circle", "FireCircle", "KaroFireCircle", "Fire Ring" }

local function DescendFrom(root, path)
	local node = root
	for _, name in ipairs(path) do
		node = node and node:FindFirstChild(name)
	end
	return node
end

local function UsableAsVfx(instance)
	if not instance then return false end
	if instance:IsA("BasePart") then return true end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") or descendant:IsA("ParticleEmitter")
			or descendant:IsA("Beam") or descendant:IsA("Trail") then
			return true
		end
	end
	return false
end

local function FindFireCircleSource()
	local home = DescendFrom(ReplicatedStorage, FIRE_CIRCLE_HOME)
	if UsableAsVfx(home) then return home end

	for _, container in ipairs({ ReplicatedStorage, Workspace }) do
		for _, name in ipairs(FIRE_CIRCLE_LEGACY) do
			local found = container:FindFirstChild(name)
			if UsableAsVfx(found) then return found end
		end
	end

	return nil
end

local fireCircleTemplate, fireCircleWarned = nil, false

local function FireCircleTemplate()
	if fireCircleTemplate then return fireCircleTemplate end

	local source = FindFireCircleSource()
	if not source then
		if not fireCircleWarned then
			fireCircleWarned = true
			warn(("HeroView: VFX/Karo/FireCircle nao encontrado em ReplicatedStorage (nem como %s no Workspace) — o giro do Karo sai sem o anel de fogo.")
				:format(table.concat(FIRE_CIRCLE_LEGACY, " / ")))
		end
		return nil
	end

	local template = source:Clone()
	SetEmitters(template, false)
	for _, descendant in ipairs(template:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.CastShadow = false
		end
	end

	fireCircleTemplate = template
	return template
end

function HeroView.PlayFireCircle(view, hexId)
	if not view then return end

	local template = FireCircleTemplate()
	if not template then return end

	local circle = template:Clone()
	local center = HexGrid.GetWorldPosition(hexId, view.origin)
		+ Vector3.new(0, TILE_TOP_Y + 0.15, 0)

	local part = circle:IsA("BasePart") and circle or circle:FindFirstChildWhichIsA("BasePart", true)

	if not part and not circle:IsA("PVInstance") then
		local host = Instance.new("Part")
		host.Name = "FireCircleHost"
		host.Size = Vector3.new(0.2, 0.2, 0.2)
		host.Transparency = 1
		host.Anchored = true
		host.CanCollide = false
		host.CanQuery = false
		host.CastShadow = false
		circle.Parent = host
		circle = host
		part = host
	end

	local anchor = part or circle
	local spin = part and part.CFrame.Rotation or CFrame.identity
	local full, seed = nil, nil

	if part then
		full = part.Size
		seed = Vector3.new(full.X, full.Y * FIRE_CIRCLE_SEED, full.Z * FIRE_CIRCLE_SEED)
		part.Size = seed
	end

	if anchor:IsA("BasePart") then
		anchor.CFrame = CFrame.new(center) * spin
	else
		anchor:PivotTo(CFrame.new(center) * spin)
	end

	circle.Parent = view.heroesFolder
	SetEmitters(circle, true)

	if part then
		TweenService:Create(part,
			TweenInfo.new(FIRE_CIRCLE_GROW, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
			{ Size = full }):Play()
	end

	task.delay(FIRE_CIRCLE_GROW + FIRE_CIRCLE_HOLD, function()
		if not circle.Parent then return end

		if part and part.Parent then
			TweenService:Create(part,
				TweenInfo.new(FIRE_CIRCLE_CLOSE, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ Size = seed }):Play()
		end

		task.delay(FIRE_CIRCLE_CLOSE, function()
			if circle.Parent then SetEmitters(circle, false) end
		end)
	end)

	Debris:AddItem(circle, FIRE_CIRCLE_GROW + FIRE_CIRCLE_HOLD + FIRE_CIRCLE_CLOSE + FIRE_CIRCLE_TAIL)
end

local CHAIN_CORE_COLOR = Color3.fromRGB(255, 250, 190)
local CHAIN_GLOW_COLOR = Color3.fromRGB(255, 214, 40)
local CHAIN_STEP = 0.07
local CHAIN_LIFE = 0.26
local CHAIN_SEGMENTS = 3
local CHAIN_JITTER = 0.9
local CHAIN_THICKNESS = 0.22

local function BuildArcSegment(parent, fromPoint, toPoint, thickness, color)
	local delta = toPoint - fromPoint
	local segment = Instance.new("Part")
	segment.Name = "ChainArc"
	segment.Size = Vector3.new(thickness, thickness, delta.Magnitude)
	segment.CFrame = CFrame.new(fromPoint + delta * 0.5, toPoint)
	segment.Color = color
	segment.Material = Enum.Material.Neon
	segment.Anchored = true
	segment.CanCollide = false
	segment.CanQuery = false
	segment.CastShadow = false
	segment.Parent = parent
	return segment
end

local function PlayArc(view, fromHex, toHex)
	local lift = Vector3.new(0, TILE_TOP_Y + SPRITE_HEIGHT * 0.35, 0)
	local origin = HexGrid.GetWorldPosition(fromHex, view.origin) + lift
	local target = HexGrid.GetWorldPosition(toHex, view.origin) + lift

	local previous = origin
	for index = 1, CHAIN_SEGMENTS do
		local straight = origin:Lerp(target, index / CHAIN_SEGMENTS)
		local point = index < CHAIN_SEGMENTS and straight + Vector3.new(
			(math.random() - 0.5) * CHAIN_JITTER,
			(math.random() - 0.5) * CHAIN_JITTER,
			(math.random() - 0.5) * CHAIN_JITTER
		) or target

		local glow = BuildArcSegment(view.heroesFolder, previous, point, CHAIN_THICKNESS * 2.1, CHAIN_GLOW_COLOR)
		glow.Transparency = 0.55
		local core = BuildArcSegment(view.heroesFolder, previous, point, CHAIN_THICKNESS, CHAIN_CORE_COLOR)

		for _, part in ipairs({ glow, core }) do
			TweenService:Create(part, TweenInfo.new(CHAIN_LIFE), { Transparency = 1 }):Play()
			Debris:AddItem(part, CHAIN_LIFE + 0.05)
		end

		previous = point
	end
end

function HeroView.PlayChainArcs(view, edges)
	if not view then return end

	for _, edge in ipairs(edges) do
		local delay = edge.depth * CHAIN_STEP
		if delay <= 0 then
			PlayArc(view, edge.from, edge.to)
		else
			task.delay(delay, function()
				if view.heroesFolder and view.heroesFolder.Parent then
					PlayArc(view, edge.from, edge.to)
				end
			end)
		end
	end
end

function HeroView.PlayIceStorm(view, hexId)
	if not view then return end

	local size = HexGrid.GetHexSize()
	local center = HexGrid.GetWorldPosition(hexId, view.origin)

	local hexIds = {}
	for _, hex in ipairs(HexGrid.GetNeighbors(hexId)) do
		table.insert(hexIds, hex.id)
	end
	table.insert(hexIds, hexId)
	HeroView.FlashAttackRange(view, hexIds, ICE_CORE, ICE_EDGE)

	local ring = Instance.new("Part")
	ring.Name = "IceStormRing"
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(0.2, size * 0.6, size * 0.6)
	ring.CFrame = CFrame.new(center + Vector3.new(0, TILE_TOP_Y + 0.1, 0)) * CFrame.Angles(0, 0, math.rad(90))
	ring.Color = ICE_CORE
	ring.Material = Enum.Material.Neon
	ring.Transparency = 0.35
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CastShadow = false
	ring.Parent = view.heroesFolder

	local grow = TweenInfo.new(ICE_STORM_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(ring, grow, {
		Size = Vector3.new(0.2, size * 4.2, size * 4.2),
		Transparency = 1,
		Color = ICE_EDGE,
	}):Play()

	Debris:AddItem(ring, ICE_STORM_TIME + 0.15)
end

-- Alguém atravessou a chama: lufada curta pra amarrar o número de dano à casa.
-- Toca sempre que uma chama é CONSUMIDA — o pedágio que mata o fogo (ver
-- MatchManager.MoveHero: dano, depois ClearFlame na mesma casa). Som próprio,
-- não o "Hit" genérico de golpe corpo a corpo: isto é a chama acabando, não
-- uma pancada.
function HeroView.PlayFlameHit(view, hexId)
	if not view then return end

	local part = view.heroesFolder:FindFirstChild(FlameName(hexId))
	if not part then return end

	PlaySound("FlameConsume", view)

	local emitter = part:FindFirstChildWhichIsA("ParticleEmitter", true)
	if emitter then emitter:Emit(18) end
end

-- A cor vem do lado (1 = azul, 2 = vermelho), não de "é o bot?": em PvP os
-- dois lados são jogadores e a câmera é a mesma pros dois.
function SideColor(sideIndex)
	return sideIndex == 2 and TEAM_COLOR_PLAYER_2 or TEAM_COLOR_PLAYER_1
end

local function TeamColor(hero)
	return SideColor(hero.sideIndex)
end

-- Pendura uma parte na âncora: sem Anchored e presa por WeldConstraint,
-- então acompanha qualquer movimento/tween da âncora.
function AttachTo(anchor, part)
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

function BuildTeamRing(anchor, hexId, color, origin)
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
		edge.Material = Enum.Material.SmoothPlastic
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
	if Hidden(hero) then return end

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
		-- Escala estática por ficha (data.scale, 1 = tamanho normal). Os mini
		-- golens usam isto pra ficar visivelmente menores que o Golem grande —
		-- sem custo nenhum no "pés plantados": SizeOffset é FRAÇÃO do próprio
		-- tamanho (ver comentário logo abaixo), então encolher os dois lados
		-- igual mantém a base no chão sozinho, sem recalcular offset nenhum.
		local scale = data.scale or 1

		local spriteGui = Instance.new("BillboardGui")
		spriteGui.MaxDistance = HERO_GUI_MAX_DISTANCE
		spriteGui.Name = "Sprite"
		spriteGui.Size = UDim2.new(
			SPRITE_WIDTH * scale, SPRITE_PIXEL_FLOOR_W * scale,
			SPRITE_HEIGHT * scale, SPRITE_PIXEL_FLOOR_H * scale)
		-- referência no topo da casa; o SizeOffset sobe a partir dali o bastante
		-- pra plantar o pé do DESENHO na casa, seja qual for o zoom, o `scale` ou
		-- a proporção da arte (ver PÉS PLANTADOS COM ScaleType.Fit)
		spriteGui.StudsOffsetWorldSpace = Vector3.new(0, -ANCHOR_LIFT, 0)
		spriteGui.SizeOffset = Vector2.new(0, FootSizeOffset(data))
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
		-- Fit, não o Stretch padrão: o recorte de cada herói (HeroData) usa a
		-- caixa REAL da arte, e a proporção dela raramente bate exata com a da
		-- moldura (165x231). Sem Fit, esse descompasso esticava/espremia o
		-- desenho pra preencher a moldura à força — com Fit ele escala mantendo
		-- a proporção própria, sobra tira fina dos lados ou em cima/embaixo em
		-- vez de distorcer o personagem. Já era assim em todo portrait do
		-- cliente (draft, retrato, destaque); só faltava aqui, no tabuleiro.
		image.ScaleType = Enum.ScaleType.Fit
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
	bubble.MaxDistance = HERO_GUI_MAX_DISTANCE
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
	statsGui.MaxDistance = HERO_GUI_MAX_DISTANCE
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
local PARALYSIS_SPARK = "ParalysisSpark"

local function SetParalysisSpark(hero, on)
	if not (hero.part and hero.part.Parent) then return end

	local existing = hero.part:FindFirstChild(PARALYSIS_SPARK, true)

	if not on then
		if existing then
			existing.Enabled = false
			Debris:AddItem(existing, 0.6)
		end
		return
	end

	if existing then
		existing.Enabled = true
		return
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = PARALYSIS_SPARK .. "Anchor"
	attachment.Position = Vector3.new(0, SPRITE_HEIGHT * 0.45, 0)
	attachment.Parent = hero.part

	local spark = Instance.new("ParticleEmitter")
	spark.Name = PARALYSIS_SPARK
	spark.Texture = FX_SPARK
	spark.Color = ColorSequence.new(Color3.fromRGB(190, 235, 255))
	spark.LightEmission = 0.9
	spark.LightInfluence = 0
	spark.Size = NumberSequence.new(0.9)
	spark.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	spark.Lifetime = NumberRange.new(0.18, 0.34)
	spark.Rate = 9
	spark.Speed = NumberRange.new(1.5, 3.5)
	spark.SpreadAngle = Vector2.new(180, 180)
	spark.Rotation = NumberRange.new(0, 360)
	spark.Parent = attachment
end

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
		-- EffectiveAttack, e não `hero.attack` cru: é o MESMO número que o
		-- Snapshot manda pra coluna de retratos, então o crachá em cima do
		-- boneco e a ficha da lateral nunca discordam. Quem muda por aqui é o
		-- Nash invisível — 2 de ficha, 6 na mão.
		local attack = GameConfig.EffectiveAttack(hero)
		atk.Value.Text = tostring(attack)

		-- Buffado = fundo e número em verde, com a moldura mais grossa. O ícone
		-- de espada continua vermelho: ele é a identidade do crachá, e trocar a
		-- cor dele junto faria os dois selos ficarem verdes e indistinguíveis.
		local buffed = attack > hero.baseAttack
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
		local poison, charge, paralysis = nil, nil, nil
		for _, effect in ipairs(hero.statusEffects) do
			if effect.type == "poison" then poison = effect
			elseif effect.type == "charge" then charge = effect
			elseif effect.type == "paralysis" then paralysis = effect end
		end

		-- o selo inteiro some sem veneno: crachá vazio com moldura dourada
		-- parecia um ícone que não carregou
		status.Visible = poison ~= nil or charge ~= nil or paralysis ~= nil

		SetParalysisSpark(hero, paralysis ~= nil)

		local spriteId = HeroData.GetPoisonSpriteId()
		if paralysis then
			icon.Visible = false
			fallback.Text = "⚡X"
		elseif charge then
			icon.Visible = false
			fallback.Text = ("⚡%d"):format(charge.stacks or 1)
		elseif poison and spriteId then

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

-- Anda UMA casa: tween + som + espera o passo terminar. Extraído de propósito
-- pra separar do que o Karo precisa fazer casa por casa (cobrar pedágio de
-- fogo com o herói já logicamente NAQUELA casa) — ver MatchManager.MoveHero.
-- Devolve `false` se o modelo sumiu no meio do caminho (herói destruído).
function HeroView.WalkStep(hero, hexId, step)
	if not (hero.part and hero.part.Parent) then return false end

	local tween = TweenService:Create(
		hero.part,
		TweenInfo.new(MOVE_STEP_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
		{ CFrame = AnchorCFrame(hexId, hero.view.origin) }
	)
	tween:Play()

	-- Zeff: passo de vento, som e rastro próprios em vez do FootstepWood
	-- genérico de todo mundo — mesmo padrão do PlayAttackSound, por
	-- habilidade e não por nome.
	if table.find(hero.abilities, "gustPush") then
		PlaySound("WindStep", hero.view)
		HeroView.PlaySkillEffect(hero, "windStep")
	elseif table.find(hero.abilities, "momentum") then
		PlaySound("WindStep", hero.view)
		HeroView.PlaySkillEffect(hero, "momentum", step or 1)
	else
		PlaySound("FootstepWood", hero.view)
	end

	task.wait(MOVE_STEP_TIME)
	return true
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
		PlaySound(hero.deathSound or "HeroDeath", hero.view)

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

-- Pura função de (herói morto) -> CFrame da lápide dele: nunca muda enquanto o
-- herói não se move (e herói morto não se move), então recalcular aqui do zero
-- a cada golpe/quebra é o que evita a lápide "derivar" de tremida em tremida —
-- mesma lógica do BarrelCFrame pro barril.
local function GraveCFrame(hero)
	return GroundCFrame(hero.position, hero.view.origin)
		* CFrame.new(0, 1.5, 0)
		* CFrame.Angles(0, math.rad(GRAVE_YAW), 0)
end

-- ===== LÁPIDE DESTRUTÍVEL =====
-- Só o time INIMIGO quebra (a checagem de dono mora no MatchManager). Mesma
-- casca escura com moldura roxa dos outros crachás — roxo, e não o âmbar do
-- barril, porque quebrar isto não é neutro: é profanar o túmulo de alguém, e
-- carrega a maldição de 1 de dano em quem desfere o golpe final.
local GRAVE_PIP_ON = Color3.fromRGB(186, 150, 220)
local GRAVE_PIP_OFF = Color3.fromRGB(56, 52, 64)
local GRAVE_PIP = 8

local function BuildGraveBadge(part, hero)
	local gui = Instance.new("BillboardGui")
	gui.MaxDistance = HERO_GUI_MAX_DISTANCE
	gui.Name = "GraveInfo"
	gui.Size = UDim2.new(0, hero.graveHitsLeft * (GRAVE_PIP + 3) + 7, 0, GRAVE_PIP + 8)
	-- acima da etiqueta do nome, que já ocupa o pé da lápide
	gui.StudsOffset = Vector3.new(0, 3.3, 0)
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
	stroke.Color = GRAVE_PIP_ON
	stroke.Thickness = 1.1
	stroke.Transparency = 0.25
	stroke.Parent = shell

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 3)
	layout.Parent = shell

	for index = 1, hero.graveHitsLeft do
		local pip = Instance.new("Frame")
		pip.Name = "Pip" .. index
		pip.LayoutOrder = index
		pip.Size = UDim2.new(0, GRAVE_PIP, 0, GRAVE_PIP)
		pip.BackgroundColor3 = GRAVE_PIP_ON
		pip.BorderSizePixel = 0
		pip.Parent = shell

		local pipCorner = Instance.new("UICorner")
		pipCorner.CornerRadius = UDim.new(0, 2)
		pipCorner.Parent = pip
	end

	return gui
end

local function UpdateGraveBadge(hero)
	local part = hero.part
	if not (part and part.Parent) then return end

	local gui = part:FindFirstChild("GraveInfo")
	local shell = gui and gui:FindFirstChild("Shell")
	if not shell then return end

	for _, pip in ipairs(shell:GetChildren()) do
		local index = tonumber(pip.Name:match("^Pip(%d+)$") or "")
		if index then
			local aceso = index <= hero.graveHitsLeft
			TweenService:Create(pip, TweenInfo.new(0.2), {
				BackgroundColor3 = aceso and GRAVE_PIP_ON or GRAVE_PIP_OFF,
			}):Play()
		end
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
	stone.CFrame = GraveCFrame(hero)
	stone.Color = Color3.fromRGB(105, 108, 118)
	stone.Material = Enum.Material.Slate
	stone.Anchored = true
	stone.CanCollide = false
	-- Clicável, ao contrário de antes: a lápide agora é um alvo de ataque como o
	-- barril, e precisa aparecer no mouse.Target do cliente pra isso funcionar.
	stone.CanQuery = true
	stone.Transparency = 1
	-- MESMO atributo que o anchor do herói vivo usa (ver HeroView.Create). É de
	-- propósito: o cliente resolve clique/mira/seleção de herói por este
	-- atributo, e herói morto continua na lista de heroes do snapshot — reusar o
	-- nome faz a lápide entrar de graça em todo esse cano sem precisar de um
	-- caminho de clique paralelo só pra ela.
	stone:SetAttribute("HeroUid", hero.uid)
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
	label.MaxDistance = HERO_GUI_MAX_DISTANCE
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

	-- `hero.part` volta a apontar pra alguma coisa: era a âncora do sprite vivo,
	-- HeroView.Destroy zerou, e agora é a pedra. Reusar o mesmo campo (em vez de
	-- inventar `hero.gravePart`) é o que deixa PlayGraveHit/DestroyGrave lerem
	-- "o Part atual deste herói" sem precisar saber se ele está vivo ou morto.
	hero.part = stone
	BuildGraveBadge(stone, hero)
end

-- Primeiro golpe (e os seguintes, até faltar um): sacode, solta poeira, apaga
-- um quadradinho e inclina mais a cada pancada — no último golpe antes de
-- quebrar, a lápide já está visivelmente caindo.
function HeroView.PlayGraveHit(hero)
	local part = hero.part
	if not (part and part.Parent) then return end

	PlaySound("Hit", hero.view)
	BarrelBurst(part, 10, 7)
	UpdateGraveBadge(hero)

	local base = GraveCFrame(hero)
	local lean = (hero.graveHitsLeft <= 1) and 14 or 6
	local settled = base * CFrame.Angles(math.rad(lean), 0, 0)

	TweenService:Create(part, TweenInfo.new(0.08, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		CFrame = base * CFrame.new(0, 0.3, 0) * CFrame.Angles(math.rad(-10), 0, 0),
	}):Play()

	task.delay(0.1, function()
		if part.Parent then
			TweenService:Create(part, TweenInfo.new(0.2, Enum.EasingStyle.Quad), { CFrame = settled }):Play()
		end
	end)
end

-- Lápide destruída pelo inimigo: vira pó, e aquele herói nunca mais pode ser
-- escolhido numa casa de promoção (a marca `graveDestroyed` mora no
-- MatchManager). Nome próprio pra não confundir com HeroView.Destroy, que
-- limpa o SPRITE do herói vivo — aqui quem some é a pedra.
function HeroView.DestroyGrave(hero)
	local part = hero.part
	hero.part = nil
	if not (part and part.Parent) then return end

	PlaySound("GraveBreak", hero.view)
	BarrelBurst(part, 30, 16)

	local badge = part:FindFirstChild("GraveInfo")
	if badge then badge.Enabled = false end
	local label = part:FindFirstChild("GraveLabel")
	if label then label.Enabled = false end

	local top = part:FindFirstChild("Top")
	part.CanQuery = false
	TweenService:Create(part, TweenInfo.new(0.5), { Transparency = 1 }):Play()
	if top then
		TweenService:Create(top, TweenInfo.new(0.5), { Transparency = 1 }):Play()
	end
	Debris:AddItem(part, 1.2)
end

-- Lápide consumida por RESSURREIÇÃO (não por ataque): some na hora, sem
-- pancada nem poeira — o efeito visual da volta é o próprio herói renascendo,
-- a lápide só precisa desocupar a casa.
function HeroView.ClearGrave(hero)
	local part = hero.part
	hero.part = nil
	if part and part.Parent then part:Destroy() end
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
