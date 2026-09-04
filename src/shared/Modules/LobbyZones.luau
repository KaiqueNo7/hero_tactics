--[[
	LobbyZones.lua
	ModuleScript — ReplicatedStorage/Modules/LobbyZones

	AS ILHAS DO LOBBY: uma ilhota por grupo da campanha, em CRUZ em volta do
	lobby, cada uma ligada a ele por uma ponte. O jogador não abre um menu pra
	ver o que falta — ele ANDA até lá.

	Já foi uma fila (lobby -> zona 1 -> zona 2 -> ...), porque na época o lobby
	era uma tigela fechada com uma única abertura a leste. O lobby foi reaberto à
	mão no Studio e a estrela passou a caber: agora toda ilha fica a uma ponte de
	casa, em vez de obrigar a atravessar as três anteriores pra chegar na quarta.

	SÓ CHÃO, BORDA E PONTE. O construtor não planta mais nada — nem árvore, nem
	pedra, nem brasa. Aquilo era gerado por código e destoava de tudo que fosse
	montado à mão. O cenário é do Studio; daqui sai a superfície e o encaixe dos
	quadrados, e nada mais.

	QUEM MANDA NAS COORDENADAS É O PLACE, NÃO ESTE ARQUIVO
	Isto aqui é a planta de PARTIDA: o construtor só levanta a trilha num place
	que ainda não tem uma (repo recém-clonado). Achando Workspace.LobbyTrail
	pronto, ele ADOTA o que está lá e não encosta em nada — nem nas ilhas, nem
	nas pontes, nem nos quadrados. Alinhar tudo à mão no Studio é o fluxo normal,
	e o ajuste fica.

	Foi o contrário até agora, e era o pior dos mundos: o play desfazia o
	alinhamento feito à mão sem erro nenhum na saída. Se quiser mesmo jogar fora
	a montagem do place e voltar pra esta planta, é explícito, pela barra de
	comando: `require(game.ServerScriptService.Modules.LobbyZoneBuilder).Build(true)`.

	Os números abaixo continuam valendo pra três coisas mesmo com a trilha
	adotada: onde o ar da zona troca (ZoneAt), onde os quadrados nascem num place
	virgem (PadSlots) e o que um rebuild forçado reproduz. Por isso eles foram
	MEDIDOS do lobby montado à mão, e não o contrário — planta e place que
	discordam viram bug silencioso.

	Este módulo é só a PLANTA (números e paleta). Quem levanta as peças é
	ServerScriptService.Modules.LobbyZoneBuilder; quem troca o ar quando o
	jogador atravessa a ponte é o LobbyClient. Mora em ReplicatedStorage porque
	os dois lados leem a mesma planta — igual ao Campaign.
]]

local LobbyZones = {}

LobbyZones.GROUND_Y = 712.42

LobbyZones.ISLAND_SPAN = 76
LobbyZones.ISLAND_THICKNESS = 8
LobbyZones.BRIDGE_WIDTH = 16
LobbyZones.BRIDGE_THICKNESS = 1.5
LobbyZones.LOBBY_CENTER = Vector2.new(1, -2)
LobbyZones.LOBBY_HALF = Vector2.new(97.5, 92.5)

LobbyZones.ZONES = {
	{
		id = "clareira",
		group = 1,
		name = "Clareira Verde",
		blurb = "Onde os primeiros desafiantes acampam.",
		center = Vector2.new(164.2, 48.4),
		rotation = 71.8,
		ground = { color = Color3.fromRGB(106, 170, 90), material = Enum.Material.Grass },
		rim = Color3.fromRGB(94, 72, 48),
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
		center = Vector2.new(47.8, -150.2),
		rotation = -17.9,
		ground = { color = Color3.fromRGB(58, 54, 68), material = Enum.Material.Ground },
		rim = Color3.fromRGB(40, 36, 48),
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
		center = Vector2.new(-161.1, -50.0),
		rotation = -14.8,
		ground = { color = Color3.fromRGB(222, 236, 246), material = Enum.Material.Snow },
		rim = Color3.fromRGB(158, 190, 212),
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
		center = Vector2.new(-52.3, 155.3),
		rotation = -20.0,
		ground = { color = Color3.fromRGB(64, 52, 50), material = Enum.Material.Basalt },
		rim = Color3.fromRGB(42, 34, 33),
		ambience = {
			Ambient = Color3.fromRGB(48, 30, 24),
			OutdoorAmbient = Color3.fromRGB(120, 82, 66),
			Atmosphere = { Density = 0.40, Haze = 2.0, Color = Color3.fromRGB(196, 138, 106), Decay = Color3.fromRGB(96, 58, 44) },
			Tint = Color3.fromRGB(255, 236, 220),
			Brightness = 2.0,
		},
	},
	{
		id = "santuario",
		group = 5,
		name = "Santuário de Brasa",
		blurb = "A mesma chama da Forja, do lado que aquece em vez de queimar.",
		center = Vector2.new(135, 158),
		rotation = 39.9,
		ground = { color = Color3.fromRGB(158, 128, 108), material = Enum.Material.Sand },
		rim = Color3.fromRGB(96, 72, 58),
		ambience = {
			Ambient = Color3.fromRGB(52, 38, 30),
			OutdoorAmbient = Color3.fromRGB(148, 114, 90),
			Atmosphere = { Density = 0.30, Haze = 1.5, Color = Color3.fromRGB(232, 188, 152), Decay = Color3.fromRGB(122, 84, 62) },
			Tint = Color3.fromRGB(255, 244, 232),
			Brightness = 2.3,
		},
	},
}

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

function LobbyZones.PadSlots(zone, count, origin)
	local slots = {}
	local spread = 24

	local x = origin and origin.X or zone.center.X
	local y = origin and origin.Y or (LobbyZones.GROUND_Y + 0.5)
	local z = origin and origin.Z or zone.center.Y

	for index = 1, count do
		local offset = (index - (count + 1) / 2) * spread
		table.insert(slots, Vector3.new(x + offset, y, z + 10))
	end
	return slots
end

function LobbyZones.LobbyEdgeToward(zoneCenter)
	local c, half = LobbyZones.LOBBY_CENTER, LobbyZones.LOBBY_HALF
	local dx, dz = zoneCenter.X - c.X, zoneCenter.Y - c.Y

	local length = math.sqrt(dx * dx + dz * dz)
	if length < 1 then return c end
	dx, dz = dx / length, dz / length

	local tx = (math.abs(dx) > 1e-6) and (half.X / math.abs(dx)) or math.huge
	local tz = (math.abs(dz) > 1e-6) and (half.Y / math.abs(dz)) or math.huge
	local t = math.min(tx, tz)

	return Vector2.new(c.X + dx * t, c.Y + dz * t)
end

return LobbyZones
