--[[
	BoardSpawner.lua
	ModuleScript — ServerScriptService/Modules/BoardSpawner
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local HexGrid = require(ReplicatedStorage.Modules.HexGrid)
local GameConfig = require(ReplicatedStorage.Modules.GameConfig)

local BoardSpawner = {}

-- ===== AJUSTE FINO =====
local HEX_RADIUS = 6
local TILE_FILL = 0.94
local TILE_THICKNESS = 1
local ARENA_OFFSET = Vector3.new(300, 0, 300)

-- ===== CONFIG =====
local POINTY_TO_FLAT_ROTATION = 30
local COLOR_A = Color3.fromRGB(120, 170, 220)
local COLOR_B = Color3.fromRGB(90, 130, 180)

local function ApplyColor(instance, color)
	if instance:IsA("BasePart") then
		if instance:IsA("UnionOperation") then
			instance.UsePartColor = true
		end
		instance.Color = color
	elseif instance:IsA("Model") then
		for _, descendant in ipairs(instance:GetDescendants()) do
			ApplyColor(descendant, color)
		end
	end
end

local function CreateHexTile(template, worldPos, color, hexId)
	local clone = template:Clone()
	local tileRadius = HEX_RADIUS * TILE_FILL

	local tileSize = Vector3.new(
		math.sqrt(3) * tileRadius,
		TILE_THICKNESS,
		2 * tileRadius
	)

	local targetCFrame = CFrame.new(worldPos)
		* CFrame.Angles(0, math.rad(POINTY_TO_FLAT_ROTATION), 0)

	if clone:IsA("Model") then
		if not clone.PrimaryPart then
			local firstPart = clone:FindFirstChildWhichIsA("BasePart", true)
			if firstPart then
				clone.PrimaryPart = firstPart
			end
		end
		clone:PivotTo(targetCFrame)
	else
		clone.Size = tileSize
		clone.CFrame = targetCFrame
		clone.Anchored = true
		clone.CanCollide = true
	end

	clone.Name = hexId
	clone:SetAttribute("HexId", hexId)
	clone:SetAttribute("BaseColor", color)
	ApplyColor(clone, color)

	local anchor = clone:IsA("Model") and clone.PrimaryPart or clone
	if anchor then
		local billboard = Instance.new("BillboardGui")
		billboard.Name = "HexLabel"
		billboard.Size = UDim2.new(0, 50, 0, 20)
		billboard.StudsOffset = Vector3.new(0, 2, 0)
		billboard.AlwaysOnTop = true
		billboard.Parent = anchor

		local clickDetector = Instance.new("ClickDetector")
		clickDetector.MaxActivationDistance = 1000
		clickDetector.Parent = anchor
		clickDetector.MouseClick:Connect(function(player)
			print(player.Name .. " clicou no hex " .. hexId)
		end)
	end

	return clone
end

-- Bonequin parado ao lado do player, olhando pro tabuleiro (mesma fórmula
-- de posicionamento que o CameraController usa pro player, deslocada).
local function SpawnBotDummy(boardFolder, groundY)
	local template = ReplicatedStorage:FindFirstChild("BotDummyTemplate")
	local source = template and template:FindFirstChildWhichIsA("Model")
	if not source then return end

	local minV, maxV = HexGrid.GetBoardBounds()
	local boardCenter = HexGrid.GetBoardCenter()

	local standPos = Vector3.new(
		minV.X - GameConfig.PLAYER_SIDE_MARGIN,
		groundY + 3,
		maxV.Z + GameConfig.PLAYER_STAND_BACK
	)
	local dummyPos = standPos - Vector3.new(GameConfig.BOT_DUMMY_GAP, 0, 0)
	local lookAt = Vector3.new(boardCenter.X, dummyPos.Y, boardCenter.Z)

	local dummy = source:Clone()
	dummy.Name = "BotDummy"
	dummy:PivotTo(CFrame.new(dummyPos, lookAt))

	for _, part in ipairs(dummy:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
		end
	end

	dummy.Parent = boardFolder
end

function BoardSpawner.SpawnBoard()
	local template = ReplicatedStorage:FindFirstChild("HexTile")
	if not template then
		error("BoardSpawner: não encontrei 'HexTile' em ReplicatedStorage. Confira o nome exato.")
	end

	HexGrid.SetHexSize(HEX_RADIUS)
	HexGrid.SetBoardOffset(ARENA_OFFSET)
	HexGrid.Generate()

	local boardFolder = Workspace:FindFirstChild("Board")
	if boardFolder then
		boardFolder:Destroy()
	end
	boardFolder = Instance.new("Folder")
	boardFolder.Name = "Board"
	boardFolder.Parent = Workspace

	local allHexes = HexGrid.GetAllHexes()
	for _, hex in ipairs(allHexes) do
		local worldPos = HexGrid.GetWorldPosition(hex.id)
		local color = (hex.col % 2 == 0) and COLOR_A or COLOR_B
		CreateHexTile(template, worldPos, color, hex.id).Parent = boardFolder
	end

	local minV, maxV = HexGrid.GetBoardBounds()
	print(("BoardSpawner: %d hexágonos, raio %.1f, tabuleiro %.0f x %.0f studs.")
		:format(#allHexes, HEX_RADIUS, maxV.X - minV.X, maxV.Z - minV.Z))

	SpawnBotDummy(boardFolder, ARENA_OFFSET.Y)

	return boardFolder
end

return BoardSpawner
