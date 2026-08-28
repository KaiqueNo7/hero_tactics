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

-- ===== MEDIDAS =====
-- O topo do GrassFloor do lobby, medido no place. Tudo nasce nivelado com ele:
-- ilha, ponte e pad no mesmo Y é o que deixa a travessia sem degrau nenhum —
-- criança não fica presa em quina.
LobbyZones.GROUND_Y = 712.42

LobbyZones.ISLAND_SPAN = 76 -- lado do quadrado de cada zona
LobbyZones.ISLAND_THICKNESS = 8
LobbyZones.BRIDGE_WIDTH = 16
LobbyZones.BRIDGE_THICKNESS = 1.5

-- ===== O LOBBY NO CENTRO =====
-- Medidos do GrassFloor do place: centro (1, -2), 195 x 185. As pontes saem da
-- BORDA dele, não do centro — daí precisar do meio-lado.
--
-- O traçado é uma ESTRELA, não uma fila: cada ilha liga direto ao lobby, e não
-- à anterior. Foi assim que o lobby acabou sendo montado à mão no Studio, e é
-- melhor mesmo — numa fila, chegar na quarta zona obrigava atravessar as três
-- primeiras; aqui toda ilha fica a uma ponte de distância de casa.
LobbyZones.LOBBY_CENTER = Vector2.new(1, -2)
LobbyZones.LOBBY_HALF = Vector2.new(97.5, 92.5)

-- ===== AS ZONAS =====
-- `center` no plano XZ e `rotation` em GRAUS, os dois MEDIDOS do lobby montado
-- à mão no Studio: as quatro ilhas ficam em CRUZ em volta do centro, cada uma a
-- uma ponte de casa, e cada uma girada pra ficar de esquadro com a ponte dela.
--
-- A rotação existe porque a ponte sai na diagonal (a reta centro-a-centro), e
-- ilha quadrada sem girar encontra a ponte torta. O construtor só usa isso num
-- place virgem ou num rebuild forçado — no place montado, ele adota o que já
-- está lá (ver cabeçalho).
--
-- NÃO existe `props`. As ilhas nascem só com chão e borda: a vegetação era
-- gerada por código e ficava suja ao lado de qualquer coisa feita à mão.
-- Cenário é do Studio; o construtor entrega a superfície e sai da frente.
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

	-- A quinta ilha NÃO é braço da cruz: os quatro braços (N/S/L/O) já estão
	-- ocupados e mexer neles desfaria o alinhamento feito à mão. Esta sai na
	-- diagonal sudeste, no vão entre a Clareira e a Forja — é o único lugar em
	-- que a ponte continua saindo direto da borda do lobby, sem precisar
	-- atravessar ilha de ninguém.
	--
	-- Fica ao lado da Forja de propósito: a Lucy é irmã do Karo e divide o fogo
	-- com ele (o mesmo match.flames), mas o payoff dela é curar em vez de bater.
	-- Por isso a paleta é a brasa MORNA — cinza clara e luz alta — e não o
	-- basalto escuro do irmão.
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

-- Por onde a ponte desta zona sai do LOBBY: o ponto em que a reta centro-a-centro
-- cruza a borda do retângulo do lobby.
--
-- Retângulo e não círculo porque o lobby é retangular (195 x 185): num círculo,
-- a ponte pro norte nasceria dentro da grama e a ponte pro leste nasceria no ar.
-- `t` é o quanto dá pra andar na direção da zona antes de furar cada lado; o
-- menor dos dois é a saída.
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
