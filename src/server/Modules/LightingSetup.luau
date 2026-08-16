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

-- A tela de carregamento (ReplicatedFirst) espera por este atributo antes de
-- liberar a entrada. O nome vive aqui pra os dois lados lerem a mesma string.
LightingSetup.READY_ATTRIBUTE = "HeroTacticsLightingReady"

-- ===== CÉU ABERTO / SOL =====
local CLOCK_TIME = 14.2 -- meio da tarde: sol inclinado dá sombra longa e macia
local GEOGRAPHIC_LATITUDE = 24 -- inclina o sol pro lado em vez de deixá-lo a pino
local BRIGHTNESS = 2.4

-- ===== LUZ INDIRETA =====
-- Ambient vale pro mundo todo (inclusive dentro da taverna); OutdoorAmbient só
-- pro que enxerga o céu. Ambient levemente azulado imita a luz do céu quicando
-- nas paredes, que é o que dá o aspecto "natural" em vez de lanterna no escuro.
local AMBIENT = Color3.fromRGB(30, 32, 40)
local OUTDOOR_AMBIENT = Color3.fromRGB(124, 132, 148)

-- Sol quente por cima, sombra fria por baixo: o contraste de temperatura é o
-- que faz o olho ler a cena como luz de verdade.
local COLOR_SHIFT_TOP = Color3.fromRGB(26, 19, 8)
local COLOR_SHIFT_BOTTOM = Color3.fromRGB(8, 11, 20)

-- O padrão (1) deixa tudo espelhado e lavado; baixar o specular devolve a
-- madeira fosca da taverna sem tirar o brilho do metal.
local ENVIRONMENT_DIFFUSE = 0.85
local ENVIRONMENT_SPECULAR = 0.35

local EXPOSURE_COMPENSATION = 0.12
local SHADOW_SOFTNESS = 0.42 -- borda de sombra difusa = "suave"

-- ===== ATMOSFERA =====
-- Dá profundidade de graça (é pós-processamento, não custa luz nenhuma).
local ATMOSPHERE = {
	Density = 0.28,
	Offset = 0.1,
	Color = Color3.fromRGB(199, 199, 199),
	Decay = Color3.fromRGB(106, 112, 125),
	Glare = 0.18,
	Haze = 1.1,
}

-- ===== PÓS-PROCESSAMENTO =====
-- Bloom discreto: o suficiente pra tocha e o Neon do anel de time "acenderem",
-- longe do borrão branco que come o contraste do tabuleiro.
local BLOOM = { Enabled = true, Intensity = 0.7, Size = 20, Threshold = 1.6 }
local SUN_RAYS = { Enabled = true, Intensity = 0.03, Spread = 0.2 }

-- Desfoque de profundidade fica DESLIGADO: a câmera olha o tabuleiro de longe e
-- de cima, então qualquer DepthOfField borra exatamente as casas que o jogador
-- precisa ler. Fica registrado aqui pra ninguém religar sem querer.
local DEPTH_OF_FIELD_ENABLED = false

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

	-- névoa legada desligada: quem faz o ar aqui é o Atmosphere
	Lighting.FogStart = 0
	Lighting.FogEnd = 100000

	ApplyProps(EnsureChild("Atmosphere", "Atmosphere"), ATMOSPHERE)
	ApplyProps(EnsureChild("BloomEffect", "Bloom"), BLOOM)
	ApplyProps(EnsureChild("SunRaysEffect", "SunRays"), SUN_RAYS)

	local depthOfField = Lighting:FindFirstChildOfClass("DepthOfFieldEffect")
	if depthOfField then
		depthOfField.Enabled = DEPTH_OF_FIELD_ENABLED
	end

	-- Bandeira pra tela de carregamento: atributo replica junto com o resto, então
	-- o cliente sabe que a luz que ele está vendo já é a definitiva e não a
	-- Lighting padrão do place. Sem isso o jogador entraria a tempo de ver a cena
	-- "acender" na frente dele.
	Lighting:SetAttribute(LightingSetup.READY_ATTRIBUTE, true)

	print("LightingSetup: paleta aplicada (ajuste Lighting.Technology na mão).")
end

return LightingSetup
