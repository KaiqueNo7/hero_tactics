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
local CollectionService = game:GetService("CollectionService")

local HexGrid = require(ReplicatedStorage.Modules.HexGrid)
local HeroData = require(ReplicatedStorage.Modules.HeroData)
local PixelIcons = require(ReplicatedStorage.Modules.PixelIcons)
local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local ViewStyle = require(script.Parent.ViewStyle)
local VfxLibrary = require(script.Parent.VfxLibrary)
local Bolt = require(script.Parent.ProjectileVfx)
local BoardVfx = require(script.Parent.BoardVfx)
local MatchAudio = require(script.Parent.MatchAudio)

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
local SPRITE_WIDTH = ViewStyle.SPRITE_WIDTH

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

local TILE_TOP_Y = ViewStyle.TILE_TOP_Y

local HERO_GUI_MAX_DISTANCE = ViewStyle.GUI_MAX_DISTANCE
local MOVE_STEP_TIME = 0.22
local BOT_ID = "BOT"


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

local BADGE_BG = ViewStyle.BADGE_BG
local BADGE_GOLD = ViewStyle.BADGE_GOLD
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
local SHOCK_ICON_COLOR = Color3.fromRGB(255, 226, 90)
local PARALYSIS_ICON_COLOR = Color3.fromRGB(212, 190, 124)
local POISON_ICON_COLORS = {
	Color3.fromRGB(170, 250, 130),
	Color3.fromRGB(126, 214, 96),
	Color3.fromRGB(92, 168, 74),
}

-- Passiva do herói (data.ability) -> ícone e cor do selo ao lado da vida
local ABILITY_BADGES = {
	Taunt  = { icon = "taunt",  color = Color3.fromRGB(198, 202, 212) },
	Sprint = { icon = "sprint", color = Color3.fromRGB(132, 206, 255) },
	Ranged = { icon = "ranged", color = Color3.fromRGB(255, 200, 110) },
	Agility = { icon = "agility", color = Color3.fromRGB(255, 170, 90) },
}

local SPRITE_HEIGHT = ViewStyle.SPRITE_HEIGHT
local ANCHOR_LIFT = ViewStyle.ANCHOR_LIFT

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
	-- Taunt barrando o golpe: mesmo balão e mesma palavra do escudo da Kira
	-- (BLOQUEADO), em AMARELO. As duas coisas são a mesma frase pro jogador —
	-- "este ataque não vai acontecer" —, e ler igual é o ponto; a cor separa o
	-- motivo, provocador puxando o foco em vez de barreira gasta.
	taunt  = { color = Color3.fromRGB(255, 214, 60),  font = Enum.Font.GothamBlack,  size = 34, rise = 2.8 },
	info   = DEFAULT_STYLE,
}

local sayQueue, sayRunning = {}, {}

-- ===== SOM =====
local PlaySound = MatchAudio.Play

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
	aegis = "SkillAegis",
	weakPoint = "SkillWeakPoint",
	shadowSwap = "SkillShadowSwap",
}

local SKILL_SOUND_FALLBACK = {
	weakPoint = "IceBreak",
}

function HeroView.PlaySkillSound(key, view)
	local name = SKILL_SOUNDS[key]
	if name and Sounds:FindFirstChild(name) then
		PlaySound(name, view)
		return
	end

	local fallback = SKILL_SOUND_FALLBACK[key]
	if fallback then PlaySound(fallback, view) end
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
local FX_SPARK = ViewStyle.FX_SPARK
local FX_SMOKE = ViewStyle.FX_SMOKE

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

	weakPoint     = { color = Color3.fromRGB(255, 255, 255), texture = FX_SPARK, shape = "burst", count = 26, size = 2.6, speed = 18 },

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

	-- Spyke: o sangue fervendo. Sobe em vez de estourar — é um estado ligando pro
	-- turno seguinte, não um golpe acontecendo agora
	vengeance      = { color = Color3.fromRGB(255, 170, 90),  texture = FX_SPARK, shape = "rise",  count = 14, size = 2.0, speed = 8 },

	-- Kira: o escudo entrando (sobe, é um estado ligando) e o escudo quebrando
	-- (estoura, é o golpe batendo nele agora). O brilho que FICA enquanto o
	-- escudo existe é outro sistema — ver HeroView.SetShieldAura.
	aegis          = { color = Color3.fromRGB(255, 226, 150), texture = FX_SPARK, shape = "rise",  count = 20, size = 2.2, speed = 7 },
	aegisBreak     = { color = Color3.fromRGB(255, 240, 200), texture = FX_SPARK, shape = "burst", count = 28, size = 2.4, speed = 20 },

	-- ===== WREN =====
	-- Estoura NO ALVO (é lá que a skill chama o Effect), não nela: o tiro dela já
	-- tem o tracejante do Bolt.Tracer cruzando o tabuleiro, e o que falta é a
	-- marca do impacto na outra ponta. Verde-espectral, a cor dela.
	longShot = { color = Color3.fromRGB(120, 225, 190), texture = FX_SPARK, shape = "burst", count = 24, size = 2.6, speed = 17 },

	raiseSkulls = { color = Color3.fromRGB(120, 245, 110), texture = FX_SMOKE, shape = "rise",  count = 24, size = 2.8, speed = 8 },
	estopim     = { color = Color3.fromRGB(150, 255, 120), texture = FX_SMOKE, shape = "burst", count = 32, size = 3.2, speed = 20 },

	-- ===== RYDER =====
	-- As pistolas carregando: faísca ciano que SOBE, mesma linguagem do vengeance
	-- e do stanceMelee — é um estado ligando pro resto do turno, não uma pancada.
	-- Curta e estreita de propósito: dispara no passo, e passo é a coisa mais
	-- frequente do jogo.
	gunCharge     = { color = Color3.fromRGB(120, 235, 255), texture = FX_SPARK, shape = "rise",  count = 14, size = 1.9, speed = 10 },

	-- ===== SHIN =====
	-- A fumaça da Troca estoura nas DUAS casas, e é escura de propósito: some
	-- rápido e não disputa leitura com nenhum golpe. As duas posturas usam a
	-- mesma forma "rise" (é um estado ligando, não uma pancada) e se separam
	-- pela cor e pela textura — lâmina fria e faísca curta pro Melee, rajada
	-- pálida e larga pro Ranged.
	shadowSwap    = { color = Color3.fromRGB(48, 44, 70),   texture = FX_SMOKE, shape = "burst", count = 26, size = 2.6, speed = 16 },
	stanceMelee   = { color = Color3.fromRGB(190, 235, 255), texture = FX_SPARK, shape = "rise",  count = 12, size = 1.8, speed = 9 },
	stanceRanged  = { color = Color3.fromRGB(215, 215, 235), texture = FX_SMOKE, shape = "rise",  count = 14, size = 2.2, speed = 11 },
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

function HeroView.ShowRangedAttack(attacker, target)
	if not attacker.part or not target.part then return end

	local view = attacker.view
	if not view then return end

	local color = Bolt.Color(attacker)
	local fromPos = attacker.part.Position
	local toPos = target.part.Position
	local style = Bolt.Style(attacker)

	local travel = math.clamp((toPos - fromPos).Magnitude / Bolt.SPEED,
		Bolt.MIN_TIME, Bolt.MAX_TIME)

	-- `style` e não o nome do herói: "spell" é o estilo que o catálogo do Bolt
	-- amarra ao longShot, então quem herdar a skill um dia herda o tracejante
	-- junto. Falhando o VFX do place (pasta renomeada, nome trocado), o
	-- VfxTemplate avisa no output e a bolinha de sempre assume — o tiro nunca
	-- fica invisível.
	local firedTracer = style == "spell" and Bolt.Tracer(view, fromPos, toPos, travel)

	if style == "spell" then
		HeroView.PlaySkillEffect(attacker, "longShot")
	end

	if not firedTracer then
		Bolt.Launch(view, fromPos, toPos, color, nil, style)
	end

	Bolt.Reticle(view, toPos - Vector3.new(0, ANCHOR_LIFT * 0.6, 0), color, travel)

	return travel
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

local GroundCFrame = ViewStyle.GroundCFrame

local function AnchorCFrame(hexId, origin)
	return GroundCFrame(hexId, origin) * CFrame.new(0, ANCHOR_LIFT, 0)
end



local SideColor = ViewStyle.SideColor
local AttachTo = ViewStyle.AttachTo
local BuildTeamRing = ViewStyle.BuildTeamRing

local function TeamColor(hero)
	return SideColor(hero.sideIndex)
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

	local poisonIcon = PixelIcons.Build("poison", statusSlot, POISON_ICON_COLORS[1], 3)
	poisonIcon.Name = "PoisonIcon"
	poisonIcon.Visible = false

	local boltIcon = PixelIcons.Build("bolt", statusSlot, SHOCK_ICON_COLOR, 3)
	boltIcon.Name = "BoltIcon"
	boltIcon.Visible = false

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
	statusFallback.AnchorPoint = Vector2.new(1, 1)
	statusFallback.Position = UDim2.fromScale(1, 1)
	statusFallback.Size = UDim2.fromScale(0.52, 0.52)
	statusFallback.BackgroundTransparency = 1
	statusFallback.Text = ""
	statusFallback.TextColor3 = SHOCK_ICON_COLOR
	statusFallback.TextStrokeColor3 = Color3.fromRGB(12, 14, 20)
	statusFallback.TextStrokeTransparency = 0.2
	statusFallback.TextScaled = true
	statusFallback.Font = Enum.Font.GothamBlack
	statusFallback.ZIndex = 4
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

-- ===== ESCUDO DOURADO (Kira) =====
local SHIELD_BUBBLE_HOME = { "VFX", "KIra", "Shield" }
local SHIELD_AURA = "ShieldAura"

local SHIELD_SCALE = 0.69
local SHIELD_OPACITY = 0.45

function HeroView.SetShieldAura(hero, on)
	if not (hero.part and hero.part.Parent) then return end

	local existing = hero.part:FindFirstChild(SHIELD_AURA)

	if not on then
		if existing then
			VfxLibrary.SetEmitters(existing, false)
			Debris:AddItem(existing, 0.6)
		end
		return
	end

	if existing then
		VfxLibrary.SetEmitters(existing, true)
		return
	end

	local template = VfxLibrary.Template(SHIELD_BUBBLE_HOME, "o escudo da Kira fica sem a bolha dourada")
	if not template then return end

	local bubble = template:Clone()
	bubble.Name = SHIELD_AURA

	bubble.Parent = hero.part

	if math.abs(SHIELD_SCALE - 1) > 0.01 then
		if bubble:IsA("BasePart") then
			bubble.Size *= SHIELD_SCALE
			for _, piece in ipairs(bubble:GetDescendants()) do
				if piece:IsA("ParticleEmitter") then
					local keys = {}
					for _, key in ipairs(piece.Size.Keypoints) do
						table.insert(keys, NumberSequenceKeypoint.new(
							key.Time, key.Value * SHIELD_SCALE, key.Envelope * SHIELD_SCALE))
					end
					piece.Size = NumberSequence.new(keys)
				end
			end
		else
			bubble:ScaleTo(SHIELD_SCALE)
		end
	end

	if bubble:IsA("BasePart") then
		bubble.CFrame = CFrame.new(hero.part.Position) * bubble.CFrame.Rotation
	else
		local box = bubble:GetBoundingBox()
		local target = CFrame.new(hero.part.Position) * box.Rotation
		bubble:PivotTo((target * box:Inverse()) * bubble:GetPivot())
	end

	VfxLibrary.Fade(bubble, SHIELD_OPACITY)

	local parts = bubble:GetDescendants()
	if bubble:IsA("BasePart") then table.insert(parts, bubble) end

	for _, part in ipairs(parts) do
		if part:IsA("BasePart") then
			part.Anchored = false
			part.Massless = true

			part.CanQuery = false
			part.CanTouch = false
			part.CanCollide = false

			part:SetAttribute("BaseTransparency", part.Transparency)

			local weld = Instance.new("WeldConstraint")
			weld.Part0 = hero.part
			weld.Part1 = part
			weld.Parent = part
		end
	end

	VfxLibrary.SetEmitters(bubble, true)
end

local MERLIN_EYE_HOME = { "VFX", "Merlin", "Red Eye" }
local FRENZY_AURA = "FrenzyAura"

local EYE_UP_FRACTION = 0.723
local EYE_SIDE_FRACTION = 0.0755
local EYE_CENTER_FRACTION = 0.153
local EYE_SCALE = 0.15
local FRENZY_EYE_TAG = "FrenzyEye"

local function AttachEye(hero, host, template, side)
	local data = HeroData.GetById(hero.dataId)
	local eye = template:Clone()
	eye.Name = "Eye" .. tostring(side)

	if eye:IsA("BasePart") then
		eye.Size *= EYE_SCALE
	else
		eye:ScaleTo(EYE_SCALE)
	end

	local parts = eye:GetDescendants()
	if eye:IsA("BasePart") then table.insert(parts, eye) end

	for _, part in ipairs(parts) do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.Massless = true
			part.CanQuery = false
			part.CanTouch = false
			part.CanCollide = false
			part:SetAttribute("BaseTransparency", part.Transparency)
		end
	end

	local artAspect = HeroData.GetArtAspect(data)
	local drawnHeight = math.min(1, FRAME_ASPECT / artAspect)
	local drawnWidth = math.min(1, artAspect / FRAME_ASPECT)

	eye:SetAttribute("EyeOffsetUp", EYE_UP_FRACTION * drawnHeight)
	eye:SetAttribute("EyeOffsetSide",
		(EYE_CENTER_FRACTION + side * EYE_SIDE_FRACTION) * drawnWidth)

	local seed = CFrame.new(hero.part.Position)
	if eye:IsA("BasePart") then eye.CFrame = seed else eye:PivotTo(seed) end

	eye.Parent = host
	CollectionService:AddTag(eye, FRENZY_EYE_TAG)

	return eye
end

local function BuildFrenzyEmber(host)
	local attachment = Instance.new("Attachment")
	attachment.Name = "EmberAnchor"
	attachment.Position = Vector3.new(0, -ANCHOR_LIFT * 0.5, 0)
	attachment.Parent = host

	local ember = Instance.new("ParticleEmitter")
	ember.Name = "Ember"
	ember.Texture = FX_SPARK
	ember.Color = ColorSequence.new(
		Color3.fromRGB(255, 90, 60), Color3.fromRGB(150, 12, 12))
	ember.LightEmission = 0.85
	ember.LightInfluence = 0
	ember.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55),
		NumberSequenceKeypoint.new(1, 0),
	})
	ember.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.25),
		NumberSequenceKeypoint.new(1, 1),
	})
	ember.Lifetime = NumberRange.new(0.7, 1.2)
	ember.Rate = 11
	ember.Speed = NumberRange.new(2.2, 3.8)
	ember.Acceleration = Vector3.new(0, 4, 0)
	ember.SpreadAngle = Vector2.new(22, 22)
	ember.Rotation = NumberRange.new(0, 360)
	ember.Parent = attachment
end

function HeroView.SetFrenzyAura(hero, on)
	if not (hero.part and hero.part.Parent) then return end

	local existing = hero.part:FindFirstChild(FRENZY_AURA)

	if not on then
		if existing then
			VfxLibrary.SetEmitters(existing, false)
			Debris:AddItem(existing, 0.6)
		end
		return
	end

	if existing then
		VfxLibrary.SetEmitters(existing, true)
		return
	end

	local host = Instance.new("Part")
	host.Name = FRENZY_AURA
	host.Size = Vector3.new(0.2, 0.2, 0.2)
	host.CFrame = CFrame.new(hero.part.Position)
	host.Transparency = 1
	host.Anchored = false
	host.Massless = true
	host.CanCollide = false
	host.CanQuery = false
	host.CanTouch = false
	host.CastShadow = false
	host:SetAttribute("BaseTransparency", 1)
	host.Parent = hero.part

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = hero.part
	weld.Part1 = host
	weld.Parent = host

	BuildFrenzyEmber(host)

	local template = VfxLibrary.Template(MERLIN_EYE_HOME, "o Frenesi do Merlin sai sem os olhos vermelhos")
	if template then
		AttachEye(hero, host, template, -1)
		AttachEye(hero, host, template, 1)
	end

	VfxLibrary.SetEmitters(host, true)
end

local WEAK_POINT_EDGE = "WeakPointEdge"
local WEAK_POINT_ATTRIBUTE = "WeakPointDirection"
local WEAK_POINT_COLOR = Color3.fromRGB(255, 255, 255)
local WEAK_POINT_DIM = Color3.fromRGB(150, 160, 185)
local WEAK_POINT_OUTLINE = Color3.fromRGB(20, 30, 55)
local WEAK_POINT_PULSE = 0.75

local WEAK_POINT_TILE_SCALE = 0.94
local WEAK_POINT_THICKNESS = 0.5
local WEAK_POINT_HEIGHT = 0.7
local WEAK_POINT_ARM = 1.5
local WEAK_POINT_ARM_ANGLE = 38
local WEAK_POINT_ARM_INSET = 1.15
local WEAK_POINT_GHOST_FILL = 0.6
local WEAK_POINT_GHOST_OUTLINE = 0.1
local WEAK_POINT_BACKING = Vector3.new(0.5, -0.08, 0.5)

local function WeakPointFrame(hero, direction)
	local view = hero.view
	local angle = HexGrid.DirectionAngle(direction)
	if not (view and angle) then return nil end

	local center = HexGrid.GetWorldPosition(hero.position, view.origin)
	local circumradius = HexGrid.GetHexSize() * WEAK_POINT_TILE_SCALE
	local apothem = circumradius * math.sqrt(3) / 2

	local outward = Vector3.new(math.cos(angle), 0, math.sin(angle))
	local tangent = Vector3.new(-math.sin(angle), 0, math.cos(angle))
	local lift = Vector3.new(0, TILE_TOP_Y + WEAK_POINT_HEIGHT / 2, 0)

	return center + outward * apothem + lift, tangent, circumradius,
		center + outward * (apothem - WEAK_POINT_ARM_INSET) + lift
end

local function WeakPointPiece(parent, anchor, size, cframe, name, dark)
	local piece = Instance.new("Part")
	piece.Name = name
	piece.Size = size
	piece.CFrame = cframe
	piece.Color = dark and WEAK_POINT_OUTLINE or WEAK_POINT_COLOR
	piece.Material = dark and Enum.Material.SmoothPlastic or Enum.Material.Neon
	piece.CastShadow = false
	piece.Anchored = false
	piece.CanCollide = false
	piece.CanQuery = false
	piece.CanTouch = false
	piece.Massless = true
	piece:SetAttribute("BaseTransparency", 0)
	piece.Parent = parent

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = anchor
	weld.Part1 = piece
	weld.Parent = piece

	return piece
end

function HeroView.SetWeakPoint(hero, direction)
	if not (hero.part and hero.part.Parent) then return end

	local existing = hero.part:FindFirstChild(WEAK_POINT_EDGE)

	if not direction then
		if existing then existing:Destroy() end
		return
	end

	if existing and existing:GetAttribute(WEAK_POINT_ATTRIBUTE) == direction then return end

	local edge, tangent, circumradius, tip = WeakPointFrame(hero, direction)
	if not edge then return end

	if existing then existing:Destroy() end

	local model = Instance.new("Model")
	model.Name = WEAK_POINT_EDGE
	model:SetAttribute(WEAK_POINT_ATTRIBUTE, direction)
	model.Parent = hero.part

	local glow = Instance.new("Model")
	glow.Name = "Glow"
	glow.Parent = model

	local barSize = Vector3.new(WEAK_POINT_THICKNESS, WEAK_POINT_HEIGHT, circumradius)
	local armSize = Vector3.new(WEAK_POINT_THICKNESS, WEAK_POINT_HEIGHT, WEAK_POINT_ARM)
	local pivot = CFrame.new(tip, tip + tangent)

	local shapes = {
		{ "Edge", barSize, CFrame.new(edge, edge + tangent) },
		{ "ArmA", armSize, pivot * CFrame.Angles(0, math.rad(WEAK_POINT_ARM_ANGLE), 0)
			* CFrame.new(0, 0, WEAK_POINT_ARM / 2) },
		{ "ArmB", armSize, pivot * CFrame.Angles(0, math.rad(-WEAK_POINT_ARM_ANGLE), 0)
			* CFrame.new(0, 0, -WEAK_POINT_ARM / 2) },
	}

	local bar
	for _, shape in ipairs(shapes) do
		local name, size, cframe = shape[1], shape[2], shape[3]
		WeakPointPiece(model, hero.part, size + WEAK_POINT_BACKING, cframe, name .. "Base", true)
		local piece = WeakPointPiece(glow, hero.part, size, cframe, name, false)
		bar = bar or piece
	end
	glow.PrimaryPart = bar

	local ghost = Instance.new("Highlight")
	ghost.Name = "WeakPointGhost"
	ghost.Adornee = glow
	ghost.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	ghost.FillColor = WEAK_POINT_COLOR
	ghost.FillTransparency = WEAK_POINT_GHOST_FILL
	ghost.OutlineColor = WEAK_POINT_OUTLINE
	ghost.OutlineTransparency = WEAK_POINT_GHOST_OUTLINE
	ghost.Parent = glow

	local pulse = TweenInfo.new(WEAK_POINT_PULSE, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
	for _, piece in ipairs(glow:GetChildren()) do
		if piece:IsA("BasePart") then
			TweenService:Create(piece, pulse, { Color = WEAK_POINT_DIM }):Play()
		end
	end
end

function HeroView.BreakWeakPoint(hero)
	if not (hero.part and hero.part.Parent) then return end

	local model = hero.part:FindFirstChild(WEAK_POINT_EDGE)
	local glow = model and model:FindFirstChild("Glow")
	local bar = glow and glow.PrimaryPart
	if not bar then return end

	local breakCFrame = bar.CFrame
	model:Destroy()

	local host = Instance.new("Part")
	host.Name = "WeakPointBreakFx"
	host.Size = Vector3.new(0.2, 0.2, 0.2)
	host.CFrame = breakCFrame
	host.Transparency = 1
	host.Anchored = true
	host.CanCollide = false
	host.CanQuery = false
	host.CanTouch = false
	host.CastShadow = false
	host.Parent = hero.part.Parent

	local attachment = Instance.new("Attachment")
	attachment.Parent = host

	local slash = Instance.new("ParticleEmitter")
	slash.Texture = FLIPBOOK_EFFECTS.beyondFront.texture
	slash.FlipbookLayout = FLIPBOOK_EFFECTS.beyondFront.layout
	slash.FlipbookFramerate = NumberRange.new(24, 24)
	slash.Lifetime = NumberRange.new(0.22, 0.22)
	slash.Size = NumberSequence.new(7)
	slash.Rate = 0
	slash.Enabled = false
	slash.LightEmission = 1
	slash.LightInfluence = 0
	slash.Speed = NumberRange.new(0)
	slash.Parent = attachment

	local shards = Instance.new("ParticleEmitter")
	shards.Texture = FX_SPARK
	shards.Color = ColorSequence.new(WEAK_POINT_COLOR)
	shards.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05),
		NumberSequenceKeypoint.new(1, 1),
	})
	shards.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.9),
		NumberSequenceKeypoint.new(1, 0),
	})
	shards.Lifetime = NumberRange.new(0.25, 0.45)
	shards.Speed = NumberRange.new(9, 20)
	shards.SpreadAngle = Vector2.new(180, 180)
	shards.Acceleration = Vector3.new(0, -22, 0)
	shards.Rotation = NumberRange.new(0, 360)
	shards.RotSpeed = NumberRange.new(-260, 260)
	shards.Drag = 3
	shards.Rate = 0
	shards.Enabled = false
	shards.LightEmission = 0.9
	shards.LightInfluence = 0
	shards.Parent = attachment

	slash:Emit(1)
	shards:Emit(24)

	Debris:AddItem(host, 1.2)
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
		local attack = GameConfig.EffectiveAttack(hero)
		atk.Value.Text = tostring(attack)

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

		local target = ratio > 0.5 and HP_TEXT_FULL
			or (ratio > 0.25 and HP_TEXT_HURT or HP_TEXT_CRITICAL)
		TweenService:Create(hp.Value, TweenInfo.new(0.25), { TextColor3 = target }):Play()
	end

	local statusSlot = status and status:FindFirstChild("Slot")
	if statusSlot then
		local poisonIcon = statusSlot:FindFirstChild("PoisonIcon")
		local boltIcon = statusSlot:FindFirstChild("BoltIcon")
		local fallback = statusSlot:FindFirstChild("Fallback")
		local poison, charge, paralysis = nil, nil, nil
		for _, effect in ipairs(hero.statusEffects) do
			if effect.type == "poison" then poison = effect
			elseif effect.type == "charge" then charge = effect
			elseif effect.type == "paralysis" then paralysis = effect end
		end

		status.Visible = poison ~= nil or charge ~= nil or paralysis ~= nil

		SetParalysisSpark(hero, paralysis ~= nil)

		poisonIcon.Visible = false
		boltIcon.Visible = false
		fallback.Text = ""

		if paralysis or charge then
			boltIcon.Visible = true
			PixelIcons.SetColor(boltIcon, paralysis and PARALYSIS_ICON_COLOR or SHOCK_ICON_COLOR)
			fallback.Text = paralysis and "" or tostring(charge.stacks or 1)
		elseif poison then
			poisonIcon.Visible = true
			PixelIcons.SetColor(poisonIcon,
				POISON_ICON_COLORS[HeroData.GetPoisonStageIndex(poison.duration) + 1]
					or POISON_ICON_COLORS[1])
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

local Swap = {
	FADE = 0.12,
	HOLD = 0.1,
}

function Swap.Puff(hero, to)
	HeroView.PlaySkillEffect(hero, "shadowSwap")

	local gui = hero.part and hero.part:FindFirstChild("Sprite")
	local image = gui and gui:FindFirstChild("Frame")
	if not image then return end

	TweenService:Create(image, TweenInfo.new(Swap.FADE, Enum.EasingStyle.Quad), {
		ImageTransparency = to,
	}):Play()
end

function HeroView.PlaySwap(one, other)
	Swap.Puff(one, 1)
	Swap.Puff(other, 1)
	HeroView.PlaySkillSound("shadowSwap", one.view)

	task.wait(Swap.FADE + Swap.HOLD)
end

function HeroView.FinishSwap(one, other)
	Swap.Puff(one, 0)
	Swap.Puff(other, 0)

	task.wait(Swap.FADE)
end

-- ===== MOVIMENTO =====
function HeroView.SetPosition(hero, hexId)
	if not hero.part then return end
	hero.part.CFrame = AnchorCFrame(hexId, hero.view.origin)
end

function HeroView.WalkStep(hero, hexId, step)
	if not (hero.part and hero.part.Parent) then return false end

	local tween = TweenService:Create(
		hero.part,
		TweenInfo.new(MOVE_STEP_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
		{ CFrame = AnchorCFrame(hexId, hero.view.origin) }
	)
	tween:Play()

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

function HeroView.Destroy(hero)
	sayQueue[hero.uid] = nil
	if hero.part then
		hero.part:Destroy()
		hero.part = nil
	end
end

local function GraveCFrame(hero)
	return GroundCFrame(hero.position, hero.view.origin)
		* CFrame.new(0, 1.5, 0)
		* CFrame.Angles(0, math.rad(GRAVE_YAW), 0)
end

local GRAVE_PIP_ON = Color3.fromRGB(186, 150, 220)
local GRAVE_PIP_OFF = Color3.fromRGB(56, 52, 64)
local GRAVE_PIP = 8

local function BuildGraveBadge(part, hero)
	local gui = Instance.new("BillboardGui")
	gui.MaxDistance = HERO_GUI_MAX_DISTANCE
	gui.Name = "GraveInfo"
	gui.Size = UDim2.new(0, hero.graveHitsLeft * (GRAVE_PIP + 3) + 7, 0, GRAVE_PIP + 8)

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

	stone.CFrame = GraveCFrame(hero)
	stone.Color = Color3.fromRGB(105, 108, 118)
	stone.Material = Enum.Material.Slate
	stone.Anchored = true
	stone.CanCollide = false

	stone.CanQuery = true
	stone.Transparency = 1
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

	TweenService:Create(stone, TweenInfo.new(0.45), { Transparency = 0 }):Play()
	TweenService:Create(top, TweenInfo.new(0.45), { Transparency = 0 }):Play()

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

	hero.part = stone
	BuildGraveBadge(stone, hero)
end

function HeroView.PlayGraveHit(hero)
	local part = hero.part
	if not (part and part.Parent) then return end

	PlaySound("Hit", hero.view)
	ViewStyle.DustBurst(part, 10, 7)
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

function HeroView.DestroyGrave(hero)
	local part = hero.part
	hero.part = nil
	if not (part and part.Parent) then return end

	PlaySound("GraveBreak", hero.view)
	ViewStyle.DustBurst(part, 30, 16)

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

function HeroView.ClearGrave(hero)
	local part = hero.part
	hero.part = nil
	if part and part.Parent then part:Destroy() end
end

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
