--[[
	LightingSetup.lua
	ModuleScript — ServerScriptService/Modules/LightingSetup

	A paleta de luz do jogo num lugar só.

	Igual ao LeaderboardBoardView, a montagem mora num módulo (e não solta dentro
	de um Script) pra poder ser chamada no Studio em modo Edit e ver o resultado
	sem dar play:

		require(game.ServerScriptService.Modules.LightingSetup).Apply()

	O que já existir em Lighting é reaproveitado: Apply() ajusta as propriedades
	dos efeitos, nunca recria o que está lá. O Sky é intocado de propósito — a
	escolha do céu é arte, não iluminação.

	POR QUE ESSES VALORES
	A arena é um diorama fechado visto de cima e o lobby é uma ilha aberta: a
	mesma Lighting precisa servir aos dois. O ajuste que mais pesa é o Ambient,
	que estava em preto puro — com ele zerado, tudo que a luz direta não alcança
	dentro da taverna vira sombra chapada e o tabuleiro some. Um Ambient baixo
	(mas não preto) levanta essas sombras sem lavar a cena.

	TECHNOLOGY (precisa ser feito na mão, uma vez)
	Lighting.Technology não é editável por script — nem em runtime, nem pelo
	plugin. Abra Lighting no Explorer e escolha na aba Properties:
	  ShadowMap  — recomendado aqui: sombra direta de verdade e roda em celular.
	  Future     — mais bonito (as tochas passam a lançar sombra), bem mais caro.
	  Voxel      — o antigo; só se o alvo for hardware muito fraco.
]]

local Lighting = game:GetService("Lighting")

local LightingSetup = {}

LightingSetup.READY_ATTRIBUTE = "HeroTacticsLightingReady"

local CLOCK_TIME = 11.6
local GEOGRAPHIC_LATITUDE = 24
local BRIGHTNESS = 2.4
local AMBIENT = Color3.fromRGB(46, 38, 33)
local OUTDOOR_AMBIENT = Color3.fromRGB(124, 132, 148)

local COLOR_SHIFT_TOP = Color3.fromRGB(26, 19, 8)
local COLOR_SHIFT_BOTTOM = Color3.fromRGB(8, 11, 20)

local ENVIRONMENT_DIFFUSE = 0.85
local ENVIRONMENT_SPECULAR = 0.35
local EXPOSURE_COMPENSATION = 0.08
local SHADOW_SOFTNESS = 0.42 

local ATMOSPHERE = {
	Density = 0.28,
	Offset = 0.1,
	Color = Color3.fromRGB(199, 199, 199),
	Decay = Color3.fromRGB(106, 112, 125),
	Glare = 0.18,
	Haze = 1.1,
}

local BLOOM = { Enabled = true, Intensity = 0.45, Size = 20, Threshold = 1.45 }
local SUN_RAYS = { Enabled = true, Intensity = 0.03, Spread = 0.2 }

local COLOR_CORRECTION = {
	Enabled = true,
	Contrast = 0.12,
	Saturation = 0.14,
	Brightness = 0,
	TintColor = Color3.fromRGB(255, 249, 242),
}

local DEPTH_OF_FIELD_ENABLED = false

local AUTO_LIGHT_NAME = "AutoLight"

local ARENA_EMITTERS = {
	-- Luz principal da sala. É luz de fora entrando, então é a mais branca e a
	-- mais forte — o contraste entre ela e o âmbar da lareira é o que dá volume.
	Janela = {
		class = "SpotLight",
		aimed = true, -- feixe descendo pro chão, como sol entrando
		props = {
			Brightness = 1.6,
			Range = 72,
			Angle = 78,
			Color = Color3.fromRGB(255, 240, 210),
			Face = Enum.NormalId.Front,
		},
	},
	Lustre = {
		class = "PointLight",
		-- Mais fraco que as janelas de propósito. O lustre fica no TOPO do
		-- enquadramento, quase colado na câmera: com o mesmo brilho das outras
		-- fontes ele lavava a metade de cima da tela inteira. Ele é decoração
		-- acesa, quem ilumina o tabuleiro são as janelas.
		props = { Brightness = 1.0, Range = 46, Color = Color3.fromRGB(255, 198, 132) },
	},
	WallLight = {
		class = "PointLight",
		props = { Brightness = 1.3, Range = 26, Color = Color3.fromRGB(255, 172, 104) },
	},
	Fireplace = {
		class = "PointLight",
		-- A lareira é alta (a chaminé sobe até o teto) e o centro da caixa dela
		-- cai no meio do cano, longe do fogo. O fogo é o que ilumina: a luz
		-- desce pra altura da brasa, medida a partir da BASE do modelo.
		heightFromBottom = 8,
		props = { Brightness = 1.7, Range = 58, Color = Color3.fromRGB(255, 138, 62) },
	},
}

local function BoundsOf(instance)
	if instance:IsA("BasePart") then
		return instance.Position, instance.Size
	end
	local cframe, size = instance:GetBoundingBox()
	return cframe.Position, size
end

function LightingSetup.LightArena(folder)
	if not folder then return end

	for _, descendant in ipairs(folder:GetDescendants()) do
		if descendant.Name == AUTO_LIGHT_NAME then
			descendant:Destroy()
		end
	end

	-- O piso é a referência da sala: sem ele não dá pra saber pra onde as
	-- janelas apontam, e aí elas ficam sem feixe (o resto da luz acende igual).
	local floor = folder:FindFirstChild("Floor", true)
	floor = floor and floor:IsA("BasePart") and floor or nil

	local floorTop = floor and (floor.Position.Y + floor.Size.Y / 2)
	local roomCenter = floor and Vector3.new(floor.Position.X, floorTop, floor.Position.Z)

	-- Cada janela ilumina o pedaço de chão DIANTE DELA, não o centro da sala.
	-- Mirar todas no centro parecia certo e não era: os quatro feixes somavam no
	-- mesmo ponto, o tabuleiro estourava de branco e o resto do chão continuava
	-- escuro. Separados, viram quatro poços de luz — que é como janela funciona,
	-- e é o que dá o gradiente no chão em vez de um holofote só.
	local BEAM_REACH = 42

	local function AimFor(position)
		local inward = ((roomCenter - position) * Vector3.new(1, 0, 1))
		if inward.Magnitude < 1 then return roomCenter end
		return Vector3.new(position.X, floorTop, position.Z) + inward.Unit * BEAM_REACH
	end

	-- Modelo que JÁ ACENDE não recebe luz nossa.
	--
	-- Os modelos do Studio vêm com iluminação embutida: o lustre tem PointLight
	-- próprio (e 26 peças Neon, que acendem sozinhas), cada arandela tem
	-- PointLight + SurfaceLight. Sem esta checagem o LightArena pendurava uma
	-- SEGUNDA luz em cima de cada uma — era isso que estourava de branco o topo
	-- do enquadramento, e nenhum ajuste de brilho resolvia, porque metade da luz
	-- vinha de instâncias que este arquivo não controla.
	--
	-- Sobra pra nós exatamente o que o cenário não resolve: o feixe das janelas
	-- (vidro não emite luz) e a lareira.
	local function HasOwnLight(instance)
		if instance:IsA("BasePart") and instance:FindFirstChildWhichIsA("Light") then
			return true
		end
		for _, d in ipairs(instance:GetDescendants()) do
			if d:IsA("Light") then return true end
		end
		return false
	end

	-- Um "WallLight" é um Model que tem dentro dele uma peça também chamada
	-- WallLight — sem esta checagem o mesmo suporte ganhava duas luzes empilhadas
	-- no mesmo ponto, dobrando o brilho e o custo. Vale a mais de fora.
	local function IsNestedEmitter(instance)
		local parent = instance.Parent
		while parent and parent ~= folder do
			if ARENA_EMITTERS[parent.Name] then return true end
			parent = parent.Parent
		end
		return false
	end

	for _, descendant in ipairs(folder:GetDescendants()) do
		local spec = ARENA_EMITTERS[descendant.Name]
		if spec and (not spec.aimed or roomCenter)
			and not IsNestedEmitter(descendant)
			and not HasOwnLight(descendant)
		then
			local center, size = BoundsOf(descendant)

			if spec.heightFromBottom then
				center = Vector3.new(center.X, center.Y - size.Y / 2 + spec.heightFromBottom, center.Z)
			end

			local anchor = Instance.new("Part")
			anchor.Name = AUTO_LIGHT_NAME
			anchor.Size = Vector3.new(0.2, 0.2, 0.2)
			anchor.Transparency = 1
			anchor.Anchored = true
			anchor.CanCollide = false
			-- invisível e fora de qualquer teste: uma peça de luz no meio da sala
			-- não pode roubar o clique de uma casa nem empurrar quem passa
			anchor.CanQuery = false
			anchor.CanTouch = false

			local aim = spec.aimed and AimFor(center)
			if aim and (aim - center).Magnitude > 1 then
				-- 3 studs pra dentro: nascendo exatamente no plano da janela, o
				-- feixe saía por dentro da parede e a sala não recebia nada
				local inward = (aim - center).Unit
				anchor.CFrame = CFrame.lookAt(center + inward * 3, aim)
			else
				anchor.CFrame = CFrame.new(center)
			end

			local light = Instance.new(spec.class)
			for key, value in pairs(spec.props) do
				light[key] = value
			end
			light.Parent = anchor

			anchor.Parent = folder
		end
	end
end

local function EnsureChild(className, name)
	local existing = Lighting:FindFirstChildOfClass(className)
	if existing then return existing end

	local instance = Instance.new(className)
	instance.Name = name
	instance.Parent = Lighting
	return instance
end

local function ApplyProps(instance, props)
	for key, value in pairs(props) do
		instance[key] = value
	end
end

function LightingSetup.Apply()
	Lighting.Ambient = AMBIENT
	Lighting.OutdoorAmbient = OUTDOOR_AMBIENT
	Lighting.Brightness = BRIGHTNESS
	Lighting.ClockTime = CLOCK_TIME
	Lighting.GeographicLatitude = GEOGRAPHIC_LATITUDE
	Lighting.GlobalShadows = true
	Lighting.ColorShift_Top = COLOR_SHIFT_TOP
	Lighting.ColorShift_Bottom = COLOR_SHIFT_BOTTOM
	Lighting.EnvironmentDiffuseScale = ENVIRONMENT_DIFFUSE
	Lighting.EnvironmentSpecularScale = ENVIRONMENT_SPECULAR
	Lighting.ExposureCompensation = EXPOSURE_COMPENSATION
	Lighting.ShadowSoftness = SHADOW_SOFTNESS

	Lighting.FogStart = 0
	Lighting.FogEnd = 100000

	ApplyProps(EnsureChild("Atmosphere", "Atmosphere"), ATMOSPHERE)
	ApplyProps(EnsureChild("BloomEffect", "Bloom"), BLOOM)
	ApplyProps(EnsureChild("SunRaysEffect", "SunRays"), SUN_RAYS)
	ApplyProps(EnsureChild("ColorCorrectionEffect", "ColorCorrection"), COLOR_CORRECTION)

	local depthOfField = Lighting:FindFirstChildOfClass("DepthOfFieldEffect")
	if depthOfField then
		depthOfField.Enabled = DEPTH_OF_FIELD_ENABLED
	end

	Lighting:SetAttribute(LightingSetup.READY_ATTRIBUTE, true)

	print("LightingSetup: paleta aplicada (ajuste Lighting.Technology na mão).")
end

return LightingSetup
