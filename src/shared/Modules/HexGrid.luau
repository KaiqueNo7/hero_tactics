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

local hexes = {}
local hexList = {}
local axialToId = {}

local function offsetToAxial(col, row0)
	local q = col
	local r = row0 - math.ceil(col / 2)
	return q, r
end

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

	local CENTER_COLUMN = 2
	local CENTER_LETTER = COLUMN_LETTERS[CENTER_COLUMN + 1]
	local CENTER_ROWS = COLUMN_COUNTS[CENTER_COLUMN + 1]

	for _, row0 in ipairs({ -1, CENTER_ROWS }) do
		local id = CENTER_LETTER .. tostring(row0 + 1) 
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

HexGrid.DIRECTION_COUNT = #AXIAL_DIRECTIONS

HexGrid.DIRECTION_NAMES = {
	"bottom-left", "bottom-right", "right", "top-right", "top-left", "left",
}

function HexGrid.DirectionName(direction)
	return HexGrid.DIRECTION_NAMES[direction] or "unknown"
end

function HexGrid.RandomDirection(exclude)
	if not exclude then return math.random(HexGrid.DIRECTION_COUNT) end

	local choice = math.random(HexGrid.DIRECTION_COUNT - 1)
	if choice >= exclude then choice += 1 end
	return choice
end

function HexGrid.NeighborInDirection(id, direction)
	local hex = hexes[id]
	local delta = AXIAL_DIRECTIONS[direction]
	if not (hex and delta) then return nil end

	return axialToId[(hex.q + delta[1]) .. "," .. (hex.r + delta[2])]
end

function HexGrid.DirectionBetween(fromId, toId)
	local from, to = hexes[fromId], hexes[toId]
	if not (from and to) then return nil end

	local dq, dr = to.q - from.q, to.r - from.r
	for index, delta in ipairs(AXIAL_DIRECTIONS) do
		if delta[1] == dq and delta[2] == dr then return index end
	end
	return nil
end

function HexGrid.DirectionAngle(direction)
	local delta = AXIAL_DIRECTIONS[direction]
	if not delta then return nil end

	local x = 3 / 2 * delta[1]
	local z = math.sqrt(3) / 2 * delta[1] + math.sqrt(3) * delta[2]
	return math.atan2(z, x)
end

function HexGrid.Exists(id)
	return hexes[id] ~= nil
end

local function AlwaysFree(id)
	return hexes[id] ~= nil
end

function HexGrid.GetWorldPosition(id, offset)
	local hex = hexes[id]
	if not hex then return nil end

	offset = offset or BOARD_OFFSET

	local x = HEX_SIZE * (3 / 2 * hex.q)
	local z = HEX_SIZE * (math.sqrt(3) / 2 * hex.q + math.sqrt(3) * hex.r)

	return Vector3.new(x + offset.X, offset.Y, z + offset.Z)
end

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

	local padX = HEX_SIZE
	local padZ = HEX_SIZE * math.sqrt(3) / 2

	local y = (offset or BOARD_OFFSET).Y

	return Vector3.new(minX - padX, y, minZ - padZ), Vector3.new(maxX + padX, y, maxZ + padZ)
end

function HexGrid.GetBoardCenter(offset)
	local minV, maxV = HexGrid.GetBoardBounds(offset)
	return (minV + maxV) / 2
end

local function HexRowSpacing()
	return HEX_SIZE * math.sqrt(3)
end

function HexGrid.GetStandPosition(slot, groundY, offset)
	local minV, maxV = HexGrid.GetBoardBounds(offset)
	local center = HexGrid.GetBoardCenter(offset)
	local outset = HexRowSpacing() * GameConfig.PLAYER_STAND_OUTSET_HEXES

	local z = (slot == 2) and (minV.Z - outset) or (maxV.Z + outset)
	return Vector3.new(center.X, groundY, z)
end

function HexGrid.GetStandFacing(slot, standPos)
	local forwardZ = (slot == 2) and 1 or -1
	return standPos + Vector3.new(0, 0, forwardZ * 10)
end

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

local LINE_NUDGE = 1e-6

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
