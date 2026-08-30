--[[
	HexGrid.lua
	ModuleScript — ReplicatedStorage/Modules/HexGrid

	Sistema único de coordenadas (axiais: q, r, s) usado tanto pra lógica
	(distância/vizinhos) quanto pra posição visual (GetWorldPosition).

	Layout "flat-top, offset-q" — equivalente ao Board.js do Phaser:
	  Phaser: xOffset += hexWidth * 0.75  ->  aqui: x = 1.5 * R * q
	  Phaser: yOffset += hexHeight        ->  aqui: z = sqrt(3) * R * r
	  Phaser: colunas ímpares -= hexHeight/2 (e 7 casas) -> aqui: offsetToAxial

	SÓ TOPOLOGIA. Com várias partidas ao mesmo tempo, todo tabuleiro tem
	exatamente as mesmas casas, vizinhos e distâncias — o que muda de uma partida
	pra outra é (a) onde ela fica no mundo e (b) quem está ocupando cada casa.
	Por isso:
	  - a geometria aceita um `offset` por chamada (a arena daquela partida);
	  - a ocupação NÃO mora aqui. Cada partida guarda a sua e passa um `isFree`
	    pras buscas. Antes era estado de módulo, e duas partidas simultâneas
	    enxergariam os heróis uma da outra.
]]

local GameConfig = require(script.Parent.GameConfig)

local HexGrid = {}

-- ===== CONFIGURAÇÃO =====
local COLUMN_LETTERS = { "A", "B", "C", "D", "E" }
local COLUMN_COUNTS = { 6, 7, 6, 7, 6 }

local HEX_SIZE = 6 -- circumradius (centro -> vértice) usado no espaçamento; definido pelo BoardSpawner
local BOARD_OFFSET = Vector3.new(0, 0, 0) -- desloca o tabuleiro inteiro (separa a arena do lobby)

function HexGrid.SetHexSize(size)
	HEX_SIZE = size
	HexGrid.HEX_SIZE = size
end

function HexGrid.GetHexSize()
	return HEX_SIZE
end

function HexGrid.SetBoardOffset(offset)
	BOARD_OFFSET = offset
end

function HexGrid.GetBoardOffset()
	return BOARD_OFFSET
end

HexGrid.HEX_SIZE = HEX_SIZE

-- ===== ESTADO INTERNO =====
local hexes = {}
local hexList = {}
local axialToId = {}

local function offsetToAxial(col, row0)
	local q = col
	local r = row0 - math.ceil(col / 2)
	return q, r
end

-- ===== GERAÇÃO =====
function HexGrid.Generate()
	hexes = {}
	hexList = {}
	axialToId = {}

	for colIndex = 0, #COLUMN_LETTERS - 1 do
		local letter = COLUMN_LETTERS[colIndex + 1]
		local count = COLUMN_COUNTS[colIndex + 1]

		for row = 1, count do
			local id = letter .. tostring(row)
			local q, r = offsetToAxial(colIndex, row - 1)

			local hex = {
				id = id,
				col = colIndex,
				row = row,
				letter = letter,
				q = q,
				r = r,
				s = -q - r,
			}

			hexes[id] = hex
			table.insert(hexList, hex)
			axialToId[q .. "," .. r] = id
		end
	end

	-- ===== CASAS DE PROMOÇÃO =====
	-- Duas casas a mais, na ponta da coluna central (C, que tem 6 linhas contra 7
	-- de B/D — por isso ela é o "meio" de verdade do tabuleiro). C0 estende antes
	-- de C1, C7 estende depois de C6.
	--
	-- Entram como hexágonos NORMAIS, não um sistema à parte: mesma tabela, mesmo
	-- axial, mesma fórmula de vizinho. Isso é o que faz Distance/GetNeighbors/
	-- ComputeReach/FindPath tratá-las como qualquer casa sem precisar de nenhuma
	-- linha extra de código — C1 ganha C0 como vizinha, C6 ganha C7, automático.
	-- GetBoardBounds também passa a incluir as duas sozinho, o que é o efeito
	-- desejado: câmera e posição dos competidores (GetStandPosition) se ajustam
	-- pra fora, dando espaço pras novas casas sem sobrepor nada — checado em jogo
	-- antes desta implementação.
	local CENTER_COLUMN = 2 -- índice de "C" em COLUMN_LETTERS (0-based)
	local CENTER_LETTER = COLUMN_LETTERS[CENTER_COLUMN + 1]
	local CENTER_ROWS = COLUMN_COUNTS[CENTER_COLUMN + 1]

	for _, row0 in ipairs({ -1, CENTER_ROWS }) do -- antes da linha 1, depois da última
		local id = CENTER_LETTER .. tostring(row0 + 1) -- row0=-1 -> "C0", row0=6 -> "C7"
		local q, r = offsetToAxial(CENTER_COLUMN, row0)

		local hex = {
			id = id,
			col = CENTER_COLUMN,
			row = row0 + 1,
			letter = CENTER_LETTER,
			q = q,
			r = r,
			s = -q - r,
		}

		hexes[id] = hex
		table.insert(hexList, hex)
		axialToId[q .. "," .. r] = id
	end

	return hexList
end

-- ===== CONSULTAS =====
function HexGrid.GetHex(id)
	return hexes[id]
end

function HexGrid.GetAllHexes()
	return hexList
end

function HexGrid.Distance(id1, id2)
	local a, b = hexes[id1], hexes[id2]
	if not a or not b then
		warn("HexGrid.Distance: hex inválido", id1, id2)
		return math.huge
	end
	return (math.abs(a.q - b.q) + math.abs(a.r - b.r) + math.abs(a.s - b.s)) / 2
end

function HexGrid.GetHexesInRange(id, range)
	local result = {}
	for _, hex in ipairs(hexList) do
		if HexGrid.Distance(id, hex.id) <= range then
			table.insert(result, hex)
		end
	end
	return result
end

local AXIAL_DIRECTIONS = {
	{ 1, 0 }, { 1, -1 }, { 0, -1 }, { -1, 0 }, { -1, 1 }, { 0, 1 },
}

function HexGrid.GetNeighbors(id)
	local hex = hexes[id]
	if not hex then return {} end

	local neighbors = {}
	for _, dir in ipairs(AXIAL_DIRECTIONS) do
		local neighborId = axialToId[(hex.q + dir[1]) .. "," .. (hex.r + dir[2])]
		if neighborId then
			table.insert(neighbors, hexes[neighborId])
		end
	end
	return neighbors
end

-- Casa existe e (na visão de quem perguntou) está vazia. Sem `isFree` assume
-- tabuleiro vazio: serve pro cliente, que já filtra pelo próprio snapshot.
function HexGrid.Exists(id)
	return hexes[id] ~= nil
end

local function AlwaysFree(id)
	return hexes[id] ~= nil
end

-- ===== GEOMETRIA =====
-- `offset` desloca o tabuleiro inteiro. O servidor passa a arena da partida; o
-- cliente omite e cai no BOARD_OFFSET de módulo, que vale pra única partida
-- que ele está jogando.
function HexGrid.GetWorldPosition(id, offset)
	local hex = hexes[id]
	if not hex then return nil end

	offset = offset or BOARD_OFFSET

	local x = HEX_SIZE * (3 / 2 * hex.q)
	local z = HEX_SIZE * (math.sqrt(3) / 2 * hex.q + math.sqrt(3) * hex.r)

	return Vector3.new(x + offset.X, offset.Y, z + offset.Z)
end

-- Cantos do tabuleiro (já incluindo a largura das peças da borda).
-- A câmera usa isso pra enquadrar o tabuleiro inteiro sem hardcodar hex nenhum.
function HexGrid.GetBoardBounds(offset)
	if #hexList == 0 then
		HexGrid.Generate()
	end

	local minX, maxX = math.huge, -math.huge
	local minZ, maxZ = math.huge, -math.huge

	for _, hex in ipairs(hexList) do
		local pos = HexGrid.GetWorldPosition(hex.id, offset)
		minX = math.min(minX, pos.X)
		maxX = math.max(maxX, pos.X)
		minZ = math.min(minZ, pos.Z)
		maxZ = math.max(maxZ, pos.Z)
	end

	-- meia-peça de margem: flat-top mede R na horizontal, sqrt(3)/2*R na vertical
	local padX = HEX_SIZE
	local padZ = HEX_SIZE * math.sqrt(3) / 2

	-- O Y sai da própria arena, não é zero fixo. Enquanto ARENA_ORIGIN morou em
	-- y=0 dava no mesmo, mas com a taverna lá em cima o zero fazia o
	-- GetBoardCenter devolver um ponto no chão do mundo — e a câmera, que orbita
	-- esse ponto, ia olhar o vazio centenas de studs abaixo do tabuleiro.
	local y = (offset or BOARD_OFFSET).Y

	return Vector3.new(minX - padX, y, minZ - padZ), Vector3.new(maxX + padX, y, maxZ + padZ)
end

function HexGrid.GetBoardCenter(offset)
	local minV, maxV = HexGrid.GetBoardBounds(offset)
	return (minV + maxV) / 2
end

-- Distância entre as LINHAS de hexágono no eixo Z. Um passo em `r` vale
-- sqrt(3)*HEX_SIZE (ver GetWorldPosition), então esta é a medida de "uma casa"
-- pra quem anda pra fora do tabuleiro.
local function HexRowSpacing()
	return HEX_SIZE * math.sqrt(3)
end

-- Onde cada competidor fica de pé: lados opostos do tabuleiro, os dois no
-- MESMO X (o centro do campo) e separados só no Z. Slot 1 fica na borda de +Z,
-- slot 2 na de -Z. Client e server chamam esta mesma função pra não divergirem.
--
-- A folga sai da borda REAL (GetBoardBounds), não do centro de um hex-âncora:
-- como B e D têm 7 linhas contra 6 de A/C/E, a borda não é reta, e medir por
-- uma coluna só deixava o bonequim caindo meio em cima de uma casa.
function HexGrid.GetStandPosition(slot, groundY, offset)
	local minV, maxV = HexGrid.GetBoardBounds(offset)
	local center = HexGrid.GetBoardCenter(offset)
	local outset = HexRowSpacing() * GameConfig.PLAYER_STAND_OUTSET_HEXES

	local z = (slot == 2) and (minV.Z - outset) or (maxV.Z + outset)
	return Vector3.new(center.X, groundY, z)
end

-- Pra onde cada um olha. Como os dois estão no mesmo X e em bordas opostas do
-- Z, andar reto no eixo Z já mira exatamente o adversário — slot 1 olha pra -Z,
-- slot 2 pra +Z. Dois treinadores encarando um ao outro por cima do campo.
function HexGrid.GetStandFacing(slot, standPos)
	local forwardZ = (slot == 2) and 1 or -1
	return standPos + Vector3.new(0, 0, forwardZ * 10)
end

-- BFS de alcance. Atravessa apenas casas livres, mas REGISTRA as ocupadas
-- que encosta (são alvos válidos de ataque, mesmo bloqueando a passagem).
-- Retorna { [hexId] = distância }. `isFree` é injetável porque o client
-- calcula ocupação a partir do snapshot, não do estado do servidor.
function HexGrid.ComputeReach(originId, maxSteps, isFree)
	isFree = isFree or AlwaysFree

	local dist = { [originId] = 0 }
	local queue = { originId }
	local head = 1

	while head <= #queue do
		local id = queue[head]
		head += 1
		local d = dist[id]

		if d < maxSteps then
			for _, neighbor in ipairs(HexGrid.GetNeighbors(id)) do
				if dist[neighbor.id] == nil then
					dist[neighbor.id] = d + 1
					if isFree(neighbor.id) then
						table.insert(queue, neighbor.id)
					end
				end
			end
		end
	end

	dist[originId] = nil
	return dist
end

-- Mesmo FORMATO da ComputeReach ({ [hexId] = distância }), regra oposta: conta
-- em LINHA DE VISADA, pela distância axial pura, sem se importar com o que está
-- no caminho.
--
-- Existe porque a ComputeReach é uma BFS que só atravessa casa livre — ela
-- mede quantos PASSOS a pé, e contorna obstáculo. Pra quem anda isso é certo;
-- pra quem atira, não: a bala não dá a volta no barril. E a diferença não é só
-- estética, ela mente no número — com um obstáculo no meio, um alvo a 4 casas
-- de distância real entra como "5 passos", e uma habilidade que cobra pela
-- distância (ver Skills.longShot) cobra 4 num tiro que o alcance tratou como 5.
-- Arredonda um ponto cúbico fracionário pra casa mais próxima. O eixo que mais
-- errou é recalculado a partir dos outros dois, que é o que mantém q+r+s = 0.
local function CubeRound(q, r, s)
	local rq, rr, rs = math.round(q), math.round(r), math.round(s)
	local dq, dr, ds = math.abs(rq - q), math.abs(rr - r), math.abs(rs - s)

	if dq > dr and dq > ds then
		rq = -rr - rs
	elseif dr > ds then
		rr = -rq - rs
	else
		rs = -rq - rr
	end
	return rq, rr
end

-- O empurrãozinho no traçado não é frescura: uma reta que passa EXATAMENTE na
-- aresta entre duas casas fica em cima do empate no arredondamento, e sem ele o
-- desempate cai pro lado que a conta escolher.
local LINE_NUDGE = 1e-6

-- Continua em linha reta ALÉM de toId, mantendo a direção from->to, UMA casa
-- por passo. Usada por beyondFront (dano em sequência), rage e gustPush
-- (empurrão).
--
-- A direção é o delta DIVIDIDO pela distância, e não o delta cru. Com o delta
-- cru, quem ataca de longe empurrava o alvo pela distância inteira do golpe: o
-- Bramm (alcance 1) funcionava por coincidência, porque ali o delta já é um
-- passo, e o Zeff (alcance 2) jogava o alvo DUAS casas adiante — quase sempre
-- fora do tabuleiro ou em cima de alguém, e por isso o empurrão dele nunca
-- acontecia e virava só o dano de bloqueado.
function HexGrid.GetLineBeyond(fromId, toId, maxSteps)
	local from, to = hexes[fromId], hexes[toId]
	if not from or not to then return {} end

	local distance = HexGrid.Distance(fromId, toId)
	if distance == 0 or distance == math.huge then return {} end

	local dq, dr = (to.q - from.q) / distance, (to.r - from.r) / distance
	local result = {}

	for step = 1, maxSteps do
		local q = to.q + dq * step + LINE_NUDGE
		local r = to.r + dr * step + LINE_NUDGE

		local rq, rr = CubeRound(q, r, -q - r)
		local id = axialToId[rq .. "," .. rr]
		if not id then break end
		table.insert(result, id)
	end

	return result
end

-- Caminho mais curto atravessando só casas livres, respeitando maxSteps.
-- Retorna a lista de hexes do primeiro passo até o destino (sem a origem),
-- ou nil se não houver caminho. Usado pra animar o herói casa por casa.
function HexGrid.FindPath(fromId, toId, maxSteps, isFree, bias)
	isFree = isFree or AlwaysFree

	local dist = { [fromId] = 0 }
	local gain = { [fromId] = 0 }
	local cameFrom = {}
	local queue = { fromId }
	local head = 1

	while head <= #queue do
		local id = queue[head]
		head += 1

		if id == toId and not bias then break end

		local d = dist[id]
		if d < maxSteps then
			for _, neighbor in ipairs(HexGrid.GetNeighbors(id)) do
				local nid = neighbor.id
				if isFree(nid) then
					local value = (gain[id] or 0) + (bias and bias(nid) or 0)

					if dist[nid] == nil then
						dist[nid] = d + 1
						gain[nid] = value
						cameFrom[nid] = id
						table.insert(queue, nid)
					elseif bias and dist[nid] == d + 1 and value > gain[nid] then
						gain[nid] = value
						cameFrom[nid] = id
					end
				end
			end
		end
	end

	if dist[toId] == nil then return nil end

	local path = {}
	local cursor = toId
	while cursor and cursor ~= fromId do
		table.insert(path, 1, cursor)
		cursor = cameFrom[cursor]
	end

	return path
end

return HexGrid
