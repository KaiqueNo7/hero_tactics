--[[
	CameraProfiles.lua
	ModuleScript — ReplicatedStorage/Modules/CameraProfiles

	O enquadramento da câmera por CONTEXTO (onde o jogador está) e por
	ORIENTAÇÃO (como a tela está).

	É AQUI QUE SE MEXE NO ENQUADRAMENTO. O CameraController deixou de guardar os
	números; ele lê um perfil e aplica. Quem decide qual perfil vale é o
	Orientation, e quem mede números novos é o voo livre de calibração (F, com
	SHOW_CAMERA_DEBUG ligado) — o HUD de lá usa a mesma origem e a mesma
	convenção de ângulo, então os valores passam direto pra cá.

	LANDSCAPE APONTA PRO GameConfig e não copia os números. Aqueles quatro
	valores ainda são lidos pelo BoardSpawner (que enquadra a arena no Edit) e
	pelo SandboxClient (comandos de câmera), então duplicá-los aqui criaria duas
	verdades que iam divergir no primeiro ajuste.

	PORTRAIT foi conferido projetando TODAS as casas na tela, com a mesma
	matemática do applyCamera, em seis formatos verticais de 9:16 a 9:22. Todas
	as casas cabem, contando a altura do sprite do herói. O comentário no perfil
	explica por que ele é quase de cima.

	As arenas não entram nessa conta: o HexGrid é o mesmo em todas, e o que muda
	entre elas é o piso. Como esta câmera fica MAIS PERTO do centro que a do
	Landscape, ela é segura em qualquer uma que o Landscape já sirva.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GameConfig = require(ReplicatedStorage.Modules.GameConfig)

local CameraProfiles = {}

CameraProfiles.LANDSCAPE = "Landscape"
CameraProfiles.PORTRAIT = "Portrait"

CameraProfiles.MATCH = "Match"
CameraProfiles.LOBBY = "Lobby"

local PROFILES = {
	Match = {
		Landscape = {
			elevation = GameConfig.CAMERA_ELEVATION,
			azimuth = GameConfig.CAMERA_AZIMUTH,
			distance = GameConfig.CAMERA_DISTANCE,
			fov = GameConfig.CAMERA_FOV,
			-- O teto do zoom existe pra câmera não sair de dentro do diorama.
			zoomMin = 0.45,
			zoomMax = 1.5,
		},

		-- PORTRAIT OLHA MAIS DE CIMA QUE O LANDSCAPE, e isso não é gosto: é o que
		-- a tela alta obriga.
		--
		-- O FieldOfView do Roblox é VERTICAL. Numa tela em pé o campo horizontal
		-- desaba junto com a largura, então quanto mais rasante a câmera, mais o
		-- tabuleiro se espalha justamente no eixo que não tem espaço. Medido: com
		-- elevação 37 o pior hexágono fica a 1.96 da meia-largura — quase o dobro
		-- do que cabe — enquanto sobra 20% de altura sem uso.
		--
		-- O tabuleiro é 48 por 83 studs. Deitado numa tela 9:19.5 ele encaixa: o
		-- lado longo vai pro eixo alto, o curto pro estreito. É por isso que o
		-- azimute é 180 e não 168: doze graus de diferença, e o 180 alinha o lado
		-- longo com a altura da tela em vez de atravessá-lo na diagonal.
		-- ELEVAÇÃO 58 É O MEIO-TERMO MEDIDO. Quanto mais rasante, menor o
		-- tabuleiro na tela e mais longe a câmera vai parar: em 37 (o pedido
		-- original) ele só cabe a 166 de distância e ocupa 37% da altura, e em 76
		-- ocupa 72% mas fica quase de cima. Em 58 o tabuleiro usa 64% da altura e
		-- a vista tem perspectiva de verdade, 14° mais inclinada que o Landscape.
		Portrait = {
			elevation = 58,
			azimuth = 180,
			distance = 160,
			fov = 38,
			-- Mesma liberdade de zoom do Landscape: uma faixa mais curta fazia o
			-- gesto de pinça parecer travado no celular.
			zoomMin = 0.45,
			zoomMax = 1.5,
		},
	},
}

-- O lobby ainda não tem enquadramento próprio: os números de Portrait dele
-- precisam ser MEDIDOS no voo livre, como os da partida foram. Até lá o lobby
-- segue a câmera de personagem de sempre, e devolver nil aqui é o que diz isso
-- ao CameraController sem ele precisar saber por quê.
PROFILES.Lobby = nil

function CameraProfiles.Get(context, orientation)
	local group = PROFILES[context]
	if not group then return nil end

	return group[orientation] or group[CameraProfiles.LANDSCAPE]
end

function CameraProfiles.Has(context)
	return PROFILES[context] ~= nil
end

return CameraProfiles
