--[[
	LobbyZones.lua
	ModuleScript — ReplicatedStorage/Modules/LobbyZones

	A TRILHA DO LOBBY: uma ilhota temática por grupo da campanha, ligadas em fila
	por pontes. O jogador não abre um menu pra ver o que falta — ele ANDA até lá,
	e cada trecho novo do caminho é um bioma diferente.

	Por que uma fila e não quatro ilhas em volta do lobby: o lobby é uma tigela
	com UMA abertura, a leste (o resto é penhasco e árvore, medido com raycast
	antes desta lista existir). Furar o anel em mais três lugares seria mexer no
	cenário à mão de quem construiu; sair pela porta que já existe não é.

	E o formato combina com a regra: a campanha é uma ESCADA (Campaign.FIGHTS,
	campo `group`), cada grupo só abre quando o anterior fecha. Uma trilha linear
	é a mesma ideia desenhada no chão — andar mais fundo é progredir.

	QUEM MANDA NAS COORDENADAS É ESTE ARQUIVO
	Mesma política do LightingSetup: o construtor reposiciona os quadrados da
	campanha nos encaixes calculados aqui toda vez que o servidor sobe. Arrastar
	um pad no Explorer não se sustenta — ele volta pro lugar no próximo play, sem
	erro nenhum na saída, que é o pior jeito de descobrir. Mexa nos números daqui.
	A saída de emergência é o atributo `KeepPosition` no pad: com ele, o
	construtor não encosta naquele quadrado.

	Este módulo é só a PLANTA (números e paleta). Quem levanta as peças é
	ServerScriptService.Modules.LobbyZoneBuilder; quem troca o ar quando o
	jogador atravessa a ponte é o LobbyClient. Mora em ReplicatedStorage porque
	os dois lados leem a mesma planta — igual ao Campaign.
]]

local LobbyZones = {}

-- ===== MEDIDAS =====
-- O topo do GrassFloor do lobby, medido no place. Tudo nasce nivelado com ele:
-- ilha, ponte e pad no mesmo Y é o que deixa a travessia sem degrau nenhum —
-- criança não fica presa em quina.
LobbyZones.GROUND_Y = 712.42

LobbyZones.ISLAND_SPAN = 76 -- lado do quadrado de cada zona
LobbyZones.ISLAND_THICKNESS = 8
LobbyZones.BRIDGE_WIDTH = 16
LobbyZones.BRIDGE_THICKNESS = 1.5

-- Onde a primeira ponte encosta no lobby. z = -16 não é chute: é o meio da
-- única faixa que sai limpa pro leste (de z=-28 a z=-4, conferida com raycast
-- rasante). Em z=0 tem penhasco a x=88.
LobbyZones.LOBBY_EXIT = Vector2.new(104, -16)

-- ===== AS ZONAS =====
-- `center` no plano XZ. O traçado desvia do platô que já existe no place
-- (X[59..160] Z[-120..-56]) — daí o S: a trilha sai a leste, sobe pelo lado de
-- fora dele e volta pra dentro no fim.
--
-- `group` amarra a zona à campanha. Não existe segunda lista de "quais heróis
-- moram aqui": os pads daquele grupo são os de Campaign.FIGHTS, e mudar um
-- herói de grupo lá muda a ilha em que ele aparece, sozinho.
--
-- `ambience` é o que o cliente aplica ao ENTRAR (ver LobbyClient). São os
-- mesmos campos do LightingSetup, de propósito: a zona é um desvio temporário
-- da paleta padrão, e voltar pro lobby é reaplicar o LightingSetup.
LobbyZones.ZONES = {
	{
		id = "clareira",
		group = 1,
		name = "Clareira Verde",
		blurb = "Onde os primeiros desafiantes acampam.",
		center = Vector2.new(168, -16),
		ground = { color = Color3.fromRGB(106, 170, 90), material = Enum.Material.Grass },
		rim = Color3.fromRGB(94, 72, 48),
		props = {
			kind = "conifer",
			count = 9,
			trunk = Color3.fromRGB(94, 66, 44),
			foliage = { Color3.fromRGB(58, 132, 62), Color3.fromRGB(74, 152, 76) },
			rock = Color3.fromRGB(126, 130, 124),
		},
		ambience = {
			Ambient = Color3.fromRGB(38, 44, 38),
			OutdoorAmbient = Color3.fromRGB(132, 146, 128),
			Atmosphere = { Density = 0.24, Haze = 0.9, Color = Color3.fromRGB(206, 214, 196), Decay = Color3.fromRGB(108, 124, 104) },
			Tint = Color3.fromRGB(252, 255, 246),
			Brightness = 2.4,
		},
	},

	{
		id = "bosque",
		group = 2,
		name = "Bosque Sombrio",
		blurb = "As árvores aqui já morreram. Alguma coisa continua andando.",
		center = Vector2.new(238, -110),
		ground = { color = Color3.fromRGB(58, 54, 68), material = Enum.Material.Ground },
		rim = Color3.fromRGB(40, 36, 48),
		props = {
			kind = "dead",
			count = 11,
			trunk = Color3.fromRGB(46, 40, 52),
			foliage = { Color3.fromRGB(66, 52, 82), Color3.fromRGB(52, 44, 68) },
			rock = Color3.fromRGB(62, 58, 74),
		},
		ambience = {
			Ambient = Color3.fromRGB(28, 24, 38),
			OutdoorAmbient = Color3.fromRGB(72, 66, 92),
			Atmosphere = { Density = 0.42, Haze = 2.2, Color = Color3.fromRGB(120, 112, 140), Decay = Color3.fromRGB(52, 46, 70) },
			Tint = Color3.fromRGB(214, 208, 238),
			Brightness = 1.5,
		},
	},

	{
		id = "geleira",
		group = 3,
		name = "Geleira",
		blurb = "O gelo do Kor não é metáfora: aqui ele é o chão.",
		center = Vector2.new(238, -216),
		ground = { color = Color3.fromRGB(222, 236, 246), material = Enum.Material.Snow },
		rim = Color3.fromRGB(158, 190, 212),
		props = {
			kind = "shard",
			count = 10,
			trunk = Color3.fromRGB(176, 214, 236),
			foliage = { Color3.fromRGB(198, 230, 248), Color3.fromRGB(164, 206, 234) },
			rock = Color3.fromRGB(206, 224, 236),
		},
		ambience = {
			Ambient = Color3.fromRGB(46, 56, 68),
			OutdoorAmbient = Color3.fromRGB(166, 190, 210),
			Atmosphere = { Density = 0.36, Haze = 1.8, Color = Color3.fromRGB(224, 238, 250), Decay = Color3.fromRGB(140, 168, 194) },
			Tint = Color3.fromRGB(236, 246, 255),
			Brightness = 2.8,
		},
	},

	{
		id = "forja",
		group = 4,
		name = "Forja de Brasa",
		blurb = "Pedra, fogo e o que sobrou de quem chegou antes.",
		center = Vector2.new(168, -300),
		ground = { color = Color3.fromRGB(64, 52, 50), material = Enum.Material.Basalt },
		rim = Color3.fromRGB(42, 34, 33),
		props = {
			kind = "ember",
			count = 10,
			trunk = Color3.fromRGB(52, 42, 40),
			foliage = { Color3.fromRGB(214, 96, 38), Color3.fromRGB(240, 140, 52) },
			rock = Color3.fromRGB(74, 62, 58),
		},
		ambience = {
			Ambient = Color3.fromRGB(48, 30, 24),
			OutdoorAmbient = Color3.fromRGB(120, 82, 66),
			Atmosphere = { Density = 0.40, Haze = 2.0, Color = Color3.fromRGB(196, 138, 106), Decay = Color3.fromRGB(96, 58, 44) },
			Tint = Color3.fromRGB(255, 236, 220),
			Brightness = 2.0,
		},
	},
}

-- ===== CONSULTAS =====
function LobbyZones.ForGroup(group)
	for _, zone in ipairs(LobbyZones.ZONES) do
		if zone.group == group then return zone end
	end
	return nil
end

function LobbyZones.GetById(id)
	for _, zone in ipairs(LobbyZones.ZONES) do
		if zone.id == id then return zone end
	end
	return nil
end

-- Em que zona está este ponto? Quadrado, não círculo: a ilha É um quadrado, e
-- testar o quadrado de verdade evita que o jogador fique "fora" da zona parado
-- no canto da própria ilha.
--
-- A margem estica a caixa pra fora, cobrindo a ponte: a troca de ar acontece na
-- travessia e não num piscar quando o pé toca a grama nova.
--
-- VENCE A MAIS PERTO, e não a primeira da lista. As ilhas não se encostam, mas
-- as caixas COM margem de duas zonas em diagonal se cruzam numa quina — e ali a
-- primeira da lista ganhava, o que dava "ainda estou na Clareira" com o jogador
-- já em cima do Bosque. Comparar a distância responde o que ele espera: a zona
-- de quem está mais perto.
local ZONE_MARGIN = 26

function LobbyZones.ZoneAt(position)
	local half = LobbyZones.ISLAND_SPAN / 2 + ZONE_MARGIN
	local best, bestDistance = nil, math.huge

	for _, zone in ipairs(LobbyZones.ZONES) do
		local dx = position.X - zone.center.X
		local dz = position.Z - zone.center.Y

		if math.abs(dx) <= half and math.abs(dz) <= half then
			local distance = dx * dx + dz * dz
			if distance < bestDistance then
				best, bestDistance = zone, distance
			end
		end
	end
	return best
end

-- Onde os quadrados de confronto daquela zona ficam, em fila virada pra ponte
-- de entrada. Uma função e não uma lista escrita à mão: mudar um herói de grupo
-- em Campaign.FIGHTS reorganiza a fila sozinho, sem ninguém editar coordenada.
function LobbyZones.PadSlots(zone, count)
	local slots = {}
	local spread = 24

	for index = 1, count do
		local offset = (index - (count + 1) / 2) * spread
		table.insert(slots, Vector3.new(
			zone.center.X + offset,
			LobbyZones.GROUND_Y + 0.5, -- meia espessura do pad: ele ASSENTA no chão
			zone.center.Y + 10
		))
	end
	return slots
end

-- A fila de travessia: lobby -> zona 1 -> zona 2 -> ... Cada par vira uma ponte.
-- Devolve pontos de CENTRO; quem recorta as bordas é o construtor, que é quem
-- sabe o tamanho da ilha.
function LobbyZones.PathPoints()
	local points = { LobbyZones.LOBBY_EXIT }
	for _, zone in ipairs(LobbyZones.ZONES) do
		table.insert(points, zone.center)
	end
	return points
end

return LobbyZones
