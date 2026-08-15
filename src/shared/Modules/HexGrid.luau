--[[
	HexGrid.lua
	ModuleScript — ReplicatedStorage/Modules/HexGrid

	Sistema único de coordenadas (axiais: q, r, s) usado tanto pra lógica
	(distância/vizinhos) quanto pra posição visual (GetWorldPosition).

	Layout "flat-top, offset-q" — equivalente ao Board.js do Phaser:
	  Phaser: xOffset += hexWidth * 0.75  ->  aqui: x = 1.5 * R * q
	  Phaser: yOffset += hexHeight        ->  aqui: z = sqrt(3) * R * r
	  Phaser: colunas ímpares -= hexHeight/2 (e 7 casas) -> aqui: offsetToAxial
]]

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
				occupiedBy = nil,
			}

			hexes[id] = hex
			table.insert(hexList, hex)
			axialToId[q .. "," .. r] = id
		end
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

function HexGrid.IsFree(id)
	local hex = hexes[id]
	return hex ~= nil and hex.occupiedBy == nil
end

function HexGrid.SetOccupant(id, characterRef)
	local hex = hexes[id]
	if hex then hex.occupiedBy = characterRef end
end

function HexGrid.ClearOccupant(id)
	local hex = hexes[id]
	if hex then hex.occupiedBy = nil end
end

-- ===== GEOMETRIA =====
function HexGrid.GetWorldPosition(id)
	local hex = hexes[id]
	if not hex then return nil end

	local x = HEX_SIZE * (3 / 2 * hex.q)
	local z = HEX_SIZE * (math.sqrt(3) / 2 * hex.q + math.sqrt(3) * hex.r)

	return Vector3.new(x + BOARD_OFFSET.X, BOARD_OFFSET.Y, z + BOARD_OFFSET.Z)
end

-- Cantos do tabuleiro (já incluindo a largura das peças da borda).
-- A câmera usa isso pra enquadrar o tabuleiro inteiro sem hardcodar hex nenhum.
function HexGrid.GetBoardBounds()
	if #hexList == 0 then
		HexGrid.Generate()
	end

	local minX, maxX = math.huge, -math.huge
	local minZ, maxZ = math.huge, -math.huge

	for _, hex in ipairs(hexList) do
		local pos = HexGrid.GetWorldPosition(hex.id)
		minX = math.min(minX, pos.X)
		maxX = math.max(maxX, pos.X)
		minZ = math.min(minZ, pos.Z)
		maxZ = math.max(maxZ, pos.Z)
	end

	-- meia-peça de margem: flat-top mede R na horizontal, sqrt(3)/2*R na vertical
	local padX = HEX_SIZE
	local padZ = HEX_SIZE * math.sqrt(3) / 2

	return Vector3.new(minX - padX, 0, minZ - padZ), Vector3.new(maxX + padX, 0, maxZ + padZ)
end

function HexGrid.GetBoardCenter()
	local minV, maxV = HexGrid.GetBoardBounds()
	return (minV + maxV) / 2
end

-- BFS de alcance. Atravessa apenas casas livres, mas REGISTRA as ocupadas
-- que encosta (são alvos válidos de ataque, mesmo bloqueando a passagem).
-- Retorna { [hexId] = distância }. `isFree` é injetável porque o client
-- calcula ocupação a partir do snapshot, não do estado do servidor.
function HexGrid.ComputeReach(originId, maxSteps, isFree)
	isFree = isFree or HexGrid.IsFree

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

-- Continua em linha reta ALÉM de toId, mantendo a direção from->to.
-- Usada por beyondFront (dano em sequência) e rage (empurrão).
function HexGrid.GetLineBeyond(fromId, toId, maxSteps)
	local from, to = hexes[fromId], hexes[toId]
	if not from or not to then return {} end

	local dq, dr = to.q - from.q, to.r - from.r
	local result = {}
	local q, r = to.q, to.r

	for _ = 1, maxSteps do
		q, r = q + dq, r + dr
		local id = axialToId[q .. "," .. r]
		if not id then break end
		table.insert(result, id)
	end

	return result
end

-- Caminho mais curto atravessando só casas livres, respeitando maxSteps.
-- Retorna a lista de hexes do primeiro passo até o destino (sem a origem),
-- ou nil se não houver caminho. Usado pra animar o herói casa por casa.
function HexGrid.FindPath(fromId, toId, maxSteps, isFree)
	isFree = isFree or HexGrid.IsFree

	local dist = { [fromId] = 0 }
	local cameFrom = {}
	local queue = { fromId }
	local head = 1

	while head <= #queue do
		local id = queue[head]
		head += 1

		if id == toId then break end

		local d = dist[id]
		if d < maxSteps then
			for _, neighbor in ipairs(HexGrid.GetNeighbors(id)) do
				if dist[neighbor.id] == nil and isFree(neighbor.id) then
					dist[neighbor.id] = d + 1
					cameFrom[neighbor.id] = id
					table.insert(queue, neighbor.id)
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
